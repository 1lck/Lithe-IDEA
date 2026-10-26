import type { StoreApi } from "zustand";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import {
  BUILD_SYSTEMS_STORE_KEY,
  buildSystemViewId,
  useBuildSystemsStore,
  type BuildSystemsState,
} from "./build-systems-store";
import { BuildRunSession, matchesBuildRun, type BuildRunState } from "./build-run-session";
import { buildDependenciesNative, type BuildDependenciesNative } from "./build-dependencies-native";
import {
  validDependencies,
  type BuildDependencyNode,
  type BuildDependenciesResult,
  type BuildDependenciesReview,
} from "./build-dependencies-types";
import { MAX_OUTPUT_SESSIONS } from "./output/build-output-store";
import { validBuildProviderReview } from "./build-systems-types";
import {
  beginBuildProviderLanguage,
  type BuildProviderLanguageInitialization,
} from "./build-provider-language";

export interface BuildDependenciesState extends BuildRunState {
  dependencies: BuildDependencyNode[] | null;
  projectId: string | null;
  stale: boolean;
  truncated: boolean;
}
interface Snapshot {
  workspaceRoot: string | null;
  generation: number | null;
  options: string | null | undefined;
  sync: string | null | undefined;
  stale: boolean | undefined;
  revocation: number;
}
/** Reuses the task/model owner's save, sync, approval, cancellation and
 * cleanup barriers. This wrapper only retains the Core tree for display. */
export class BuildDependenciesSession {
  readonly run: BuildRunSession;
  #state: BuildDependenciesState;
  #listeners = new Set<() => void>();
  #epoch = 0;
  #approved: Snapshot | null = null;
  #published: Snapshot | null = null;
  #candidate: BuildDependenciesResult | null = null;
  #review: BuildDependenciesReview | null = null;
  #validationError: string | null = null;
  #attached = 0;
  #sharedController: AbortController | null = null;
  #sharedInitialization: BuildProviderLanguageInitialization | null = null;
  constructor(
    readonly workspaceId: string,
    readonly pluginId: string,
    readonly buildSystemId: string,
    readonly root: string,
    private store: StoreApi<BuildSystemsState>,
    readonly native: BuildDependenciesNative = buildDependenciesNative,
  ) {
    this.run = new BuildRunSession(
      workspaceId,
      pluginId,
      buildSystemId,
      root,
      store,
      {
        ...native,
        prepare: async (workspaceRoot, plugin, system, instance, selection) => {
          const review = await native.prepare(workspaceRoot, plugin, system, instance, {
            projectId: selection.projectId,
          });
          this.#review = review;
          this.#approved = this.#snapshot();
          return review;
        },
        validateReview: (review, selection) => {
          native.validateReview?.(review, selection);
          if (
            !validBuildProviderReview(review) ||
            review.kind !== "dependencies" ||
            (review as BuildDependenciesReview).projectId !== selection.projectId
          )
            throw new Error("plugin.build.staleContext");
        },
        execute: async (operationId) => {
          const epoch = this.#epoch;
          if (!this.#review) throw new Error("plugin.build.staleContext");
          this.#sharedController = new AbortController();
          this.#sharedInitialization = beginBuildProviderLanguage(
            this.#review,
            this.#sharedController.signal,
          );
          await this.#sharedInitialization.ready;
          if (epoch !== this.#epoch || !this.#approved || !this.#current(this.#approved))
            throw new Error("plugin.build.cancelled");
          const result = await native.execute(operationId);
          const review = this.#review;
          if (
            !review ||
            !result ||
            !matchesBuildRun(review, { ...result, type: "terminal" }) ||
            result.projectId !== review.projectId ||
            result.kind !== "dependencies" ||
            (result.truncated != null && typeof result.truncated !== "boolean") ||
            (result.terminal.kind === "succeeded"
              ? !validDependencies(result.dependencies)
              : result.dependencies !== null)
          ) {
            this.#validationError = "plugin.build.invalidOutput";
            throw new Error("plugin.build.invalidOutput");
          }
          this.#candidate = result;
          return result.terminal;
        },
        cancel: async (operationId) => {
          this.#epoch += 1;
          this.#candidate = null;
          this.#sharedController?.abort();
          await native.cancel(operationId);
          await this.#sharedInitialization?.cleanup();
        },
      },
      `build-dependencies-output:${JSON.stringify([pluginId, buildSystemId, root])}`,
    );
    this.#state = {
      ...this.run.getSnapshot(),
      dependencies: null,
      projectId: null,
      stale: false,
      truncated: false,
    };
  }
  getSnapshot = () => this.#state;
  subscribe = (listener: () => void) => {
    this.#listeners.add(listener);
    return () => {
      this.#listeners.delete(listener);
    };
  };
  get canEvict() {
    return this.run.canEvict;
  }
  #emit(patch: Partial<BuildDependenciesState>) {
    this.#state = { ...this.#state, ...this.run.getSnapshot(), ...patch };
    for (const listener of this.#listeners) listener();
  }
  #snapshot(): Snapshot {
    const state = this.store.getState();
    const instance = state.windows[
      buildSystemViewId(this.pluginId, this.buildSystemId)
    ]?.instances.find((row) => row.root === this.root);
    return {
      workspaceRoot: state.workspaceRoot,
      generation: state.generation,
      options: instance?.optionFingerprint,
      sync: instance?.syncDigest,
      stale: instance?.stale,
      revocation: state.pluginRevocationEpochs[this.pluginId] ?? 0,
    };
  }
  #current(snapshot: Snapshot) {
    const now = this.#snapshot();
    const runtime = workspaceRuntimeRegistry.getWorkspace(this.workspaceId);
    const state = this.store.getState();
    return (
      workspaceRuntimeRegistry.getActiveWorkspaceId() === this.workspaceId &&
      runtime?.status === "ready" &&
      runtime.stores.get(BUILD_SYSTEMS_STORE_KEY) === this.store &&
      runtime.descriptor.path === snapshot.workspaceRoot &&
      !state.revokedPlugins[this.pluginId] &&
      state.windows[buildSystemViewId(this.pluginId, this.buildSystemId)]?.selectedRoot ===
        this.root &&
      (Object.keys(snapshot) as Array<keyof Snapshot>).every((key) => snapshot[key] === now[key])
    );
  }
  attach() {
    this.#attached += 1;
    const releaseRun = this.run.attach();
    const releaseRunState = this.run.subscribe(() => this.#emit({}));
    const check = () => {
      if (this.#published && !this.#current(this.#published)) this.#emit({ stale: true });
    };
    const releaseStore = this.store.subscribe(check);
    const releaseRuntime = workspaceRuntimeRegistry.subscribe(check);
    check();
    let released = false;
    return () => {
      if (released) return;
      released = true;
      --this.#attached;
      this.#epoch += 1;
      releaseStore();
      releaseRuntime();
      releaseRunState();
      releaseRun();
    };
  }
  decide(accepted: boolean) {
    this.run.decide(accepted);
  }
  cancel() {
    this.#epoch += 1;
    return this.run.cancel();
  }
  async start(projectId: string | null) {
    if (
      ["preparing", "review", "starting", "running", "stopping", "cancelFailed"].includes(
        this.run.getSnapshot().phase,
      )
    )
      return;
    const epoch = ++this.#epoch;
    this.#candidate = null;
    this.#approved = null;
    this.#published = null;
    this.#review = null;
    this.#sharedInitialization = null;
    this.#sharedController = null;
    this.#validationError = null;
    this.#emit({ dependencies: null, projectId, stale: false, truncated: false });
    await this.run.start({
      kind: "dependencies",
      projectId,
      taskId: null,
      targetId: null,
      modelTaskId: null,
      suite: null,
      case: null,
      userArguments: [],
    });
    // A terminal event may already prove cleanup before an invalid invoke
    // payload arrives. Preserve that proof, but report a failed tree read.
    if (
      epoch === this.#epoch &&
      this.#validationError &&
      this.run.getSnapshot().phase === "ended"
    ) {
      this.#emit({ phase: "failed", error: this.#validationError });
      return;
    }
    const result = this.#candidate as BuildDependenciesResult | null;
    const approved = this.#approved as Snapshot | null;
    if (
      epoch === this.#epoch &&
      this.#attached > 0 &&
      result?.terminal.kind === "succeeded" &&
      approved &&
      this.#current(approved) &&
      this.run.getSnapshot().phase === "ended"
    ) {
      this.#published = approved;
      this.#emit({
        dependencies: result.dependencies,
        projectId,
        stale: false,
        truncated: result.truncated === true,
      });
    }
  }
}
const sessions = new WeakMap<StoreApi<BuildSystemsState>, Map<string, BuildDependenciesSession>>();
export function getBuildDependenciesSession(
  workspaceId: string,
  pluginId: string,
  buildSystemId: string,
  root: string,
  native: BuildDependenciesNative = buildDependenciesNative,
) {
  const store = useBuildSystemsStore.getStore(workspaceId);
  const rows = sessions.get(store) ?? new Map<string, BuildDependenciesSession>();
  sessions.set(store, rows);
  const key = JSON.stringify([pluginId, buildSystemId, root]);
  const existing = rows.get(key);
  if (existing) return existing;
  if (rows.size >= MAX_OUTPUT_SESSIONS) {
    const free = [...rows].find(([, row]) => row.canEvict);
    if (!free) throw new Error("plugin.build.busy");
    rows.delete(free[0]);
  }
  const session = new BuildDependenciesSession(
    workspaceId,
    pluginId,
    buildSystemId,
    root,
    store,
    native,
  );
  rows.set(key, session);
  return session;
}
