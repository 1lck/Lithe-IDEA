import { invoke } from "@/platform/tauri-core";
import { BuildRunSession } from "@/features/build-systems/build-run-session";
import { BuildDependenciesSession } from "@/features/build-systems/build-dependencies-session";
import { buildRunNative, type BuildRunNative } from "@/features/build-systems/build-run-native";
import {
  BuildModelCancellationError,
  cancelBuildModel,
  loadBuildModel,
} from "@/features/build-systems/build-systems-service";
import { buildSystemViewId } from "@/features/build-systems/build-systems-store";
import type { BuildRunSelection } from "@/features/build-systems/build-run-types";
import type {
  BuildModelLoadResult,
  BuildModelReview,
  BuildView,
} from "@/features/build-systems/build-systems-types";
import type {
  BuildDependenciesResult,
  BuildDependenciesReview,
} from "@/features/build-systems/build-dependencies-types";
import type { PluginWebBuildRequest, PluginWebBuildWorkspace } from "./plugin-web-build";
import type { WebBuildApproval } from "./plugin-web-build-approval";

interface Context {
  pluginId: string;
  buildSystemId: string;
  root: string;
  workspaceRoot: string;
  modelSource: string | null;
  selection: BuildRunSelection;
  cancelled?: boolean;
}
type Phase = "inspect" | "prepare" | "execute" | "finish" | "cancel" | "staticRefresh";
export interface WebBuildWorkflowPort {
  action<T>(token: string, phase: Phase): Promise<T>;
  native: BuildRunNative;
  approval(): Promise<WebBuildApproval>;
  loadModel: typeof loadBuildModel;
  cancelModel: typeof cancelBuildModel;
}
const nativePort: WebBuildWorkflowPort = {
  action: (operationId, phase) =>
    invoke("declarative_plugins_web_build_action", { operationId, phase }),
  native: buildRunNative,
  approval: async () => (await import("./plugin-web-build-approval")).createWebBuildApproval(),
  loadModel: loadBuildModel,
  cancelModel: cancelBuildModel,
};
// These are references to existing native owners, retained only for Stop retry.
// No second process registry, argv expansion or output parser lives here.
const active = new Map<
  PluginWebBuildWorkspace["store"],
  { token: string; cancel(): Promise<void> }
>();

export async function runPluginWebBuildWorkflow(
  request: PluginWebBuildRequest,
  workspace: PluginWebBuildWorkspace,
  signal: AbortSignal,
  port: WebBuildWorkflowPort = nativePort,
): Promise<void> {
  const current = () => {
    if (signal.aborted) throw new Error("plugin.build.staleContext");
  };
  current();
  const context = await port.action<Context>(request.operationId, "inspect");
  current();
  if (request.method === "build.cancel") return;
  if (context.pluginId !== request.pluginId || context.workspaceRoot !== workspace.path)
    throw new Error("plugin.build.staleContext");
  if (active.has(workspace.store) || workspace.store.getState().status === "loading")
    throw new Error("plugin.build.busy");
  const store = workspace.store;
  const viewId = buildSystemViewId(context.pluginId, context.buildSystemId);
  store.getState().actions.selectInstance(viewId, context.root);
  const action = <T>(phase: Phase) => port.action<T>(request.operationId, phase);
  const cancelNative = async () => {
    await action("cancel");
  };
  const entry = { token: request.operationId, cancel: cancelNative };
  active.set(store, entry);
  let release: (() => void) | null = null;
  let releaseState: (() => void) | null = null;
  let approval: WebBuildApproval | null = null;
  let retained = false;
  let run: BuildRunSession | null = null;
  const reviewController = { current: null as AbortController | null };
  let executed = false;
  let outputShown = false;
  const abort = () => {
    void entry.cancel().catch(() => {
      retained = true;
    });
  };
  signal.addEventListener("abort", abort, { once: true });
  try {
    approval = await port.approval();
    current();
    if (request.method === "build.refresh") {
      await port.native.save(workspace.id);
      current();
      await port.native.sync(context.pluginId, context.buildSystemId, context.root);
      current();
      if (context.modelSource === "static" || context.modelSource === "hostIntegration") {
        const version = store.getState().actions.beginRequest();
        try {
          const view = await action<BuildView>("staticRefresh");
          current();
          store.getState().actions.applyView(view, version);
        } finally {
          store.getState().actions.cancelRequest(version);
        }
      } else {
        const definition = await port.native.definition(context.pluginId, context.buildSystemId);
        current();
        const result = await port.loadModel(
          context.pluginId,
          context.buildSystemId,
          context.root,
          (review, nativeSignal) => approval!.approve(review, definition.programs, nativeSignal),
          {},
          {
            signal,
            onPrepared: (review) => {
              // Shared language cleanup belongs to the existing model owner.
              // Page cancellation and Retry must include that owner, not only
              // the native build token, which deliberately preserves shared LSP.
              entry.cancel = () => port.cancelModel(review.operationId);
            },
            native: {
              prepare: () => action<BuildModelReview>("prepare"),
              load: () => action<BuildModelLoadResult>("execute"),
              cancel: cancelNative,
            },
          },
        );
        current();
        if (!result) throw new Error("plugin.build.cancelled");
      }
      await action("finish");
      return;
    }
    const common: BuildRunNative = {
      ...port.native,
      prepare: () => action("prepare"),
      execute: () => {
        executed = true;
        return action("execute");
      },
      cancel: cancelNative,
    };
    let start: () => Promise<void>;
    if (request.method === "build.dependencies") {
      const dependencies = new BuildDependenciesSession(
        workspace.id,
        context.pluginId,
        context.buildSystemId,
        context.root,
        store,
        {
          ...common,
          prepare: () => action<BuildDependenciesReview>("prepare"),
          execute: () => {
            executed = true;
            return action<BuildDependenciesResult>("execute");
          },
        },
      );
      run = dependencies.run;
      release = dependencies.attach();
      start = () => dependencies.start(context.selection.projectId);
    } else {
      run = new BuildRunSession(
        workspace.id,
        context.pluginId,
        context.buildSystemId,
        context.root,
        store,
        common,
      );
      release = run.attach();
      start = () => run!.start(context.selection);
    }
    entry.cancel = () => run!.cancel();
    let reviewing: string | null = null;
    releaseState = run.subscribe(() => {
      const state = run!.getSnapshot();
      if (state.review && reviewing !== state.review.operationId) {
        reviewing = state.review.operationId;
        reviewController.current?.abort();
        reviewController.current = new AbortController();
        if (signal.aborted) reviewController.current.abort();
        void approval!
          .approve(state.review, state.programs, reviewController.current.signal)
          .then((accepted) => run!.decide(accepted && !signal.aborted));
      } else if (!state.review) {
        reviewController.current?.abort();
        reviewController.current = null;
        if (
          state.phase === "running" ||
          state.phase === "cancelFailed" ||
          (executed && state.phase === "ended")
        ) {
          outputShown = true;
          approval!.show(run!);
        }
      }
    });
    await start();
    retained = run.getSnapshot().phase === "cancelFailed";
    if (retained) throw new Error(run.getSnapshot().error ?? "plugin.build.busy");
    current();
    if (!executed) throw new Error("plugin.build.cancelled");
    if (run.getSnapshot().phase === "failed")
      throw new Error(run.getSnapshot().error ?? "plugin.build.unavailable");
    if (request.method === "build.dependencies") await action("finish");
  } catch (error) {
    if (!run && (retained || error instanceof BuildModelCancellationError)) {
      retained = true;
      approval?.failed(String(error), async () => {
        await entry.cancel();
        if (active.get(store) === entry) active.delete(store);
      });
    }
    throw error;
  } finally {
    reviewController.current?.abort();
    signal.removeEventListener("abort", abort);
    if (!retained) {
      releaseState?.();
      release?.();
      if (!outputShown) approval?.close();
      if (active.get(store) === entry) active.delete(store);
    } else if (run) {
      // Keep subscriptions, output and Retry bound to the same native ID.
      const releaseAfterCleanup = run.subscribe(() => {
        if (run!.getSnapshot().phase !== "ended") return;
        releaseAfterCleanup();
        releaseState?.();
        release?.();
        if (active.get(store) === entry) active.delete(store);
      });
    }
  }
}
