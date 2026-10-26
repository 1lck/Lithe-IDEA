import type { StoreApi } from "zustand";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import {
  BUILD_SYSTEMS_STORE_KEY,
  buildSystemViewId,
  useBuildSystemsStore,
  type BuildSystemsState,
  type BuildRequestVersion,
} from "./build-systems-store";
import { buildRunNative, type BuildRunNative } from "./build-run-native";
import type { BuildRunDefinition, BuildRunReview, BuildRunSelection } from "./build-run-types";
import {
  MAX_OUTPUT_SESSIONS,
  useBuildOutputStore,
  type BuildOutputState,
} from "./output/build-output-store";
import {
  buildOutputSessionId,
  type BuildOperationIdentity,
  type BuildOutputEvent,
  type BuildOutputPort,
  type BuildRunTerminal,
} from "./output/build-output-types";

export interface BuildRunState {
  phase:
    | "idle"
    | "preparing"
    | "review"
    | "starting"
    | "running"
    | "stopping"
    | "cancelFailed"
    | "failed"
    | "ended";
  review: BuildRunReview | null;
  programs: unknown[];
  error: string | null;
}
interface Attempt {
  controller: AbortController;
  review: BuildRunReview | null;
  decide: ((accepted: boolean) => void) | null;
  executed: boolean;
  settled: boolean;
  finished: boolean;
  terminalEvent: boolean;
  cancellation: Promise<void> | null;
  cleanupError: string | null;
  request: BuildRequestVersion | null;
  sequence: number;
  generation: number | null;
  fingerprint: string | null | undefined;
  syncDigest: string | null | undefined;
  stale: boolean | undefined;
  revocation: number;
  syncing: boolean;
  window: string;
}
const message = (error: unknown) => (error instanceof Error ? error.message : String(error));
const identityKeys = [
  "operationId",
  "pluginId",
  "buildSystemId",
  "workspaceRoot",
  "root",
  "generation",
] as const;
/** A successful invoke may arrive ahead of queued WebView output events. */
export const OUTPUT_DRAIN_TIMEOUT_MS = 5000;
export function matchesBuildRun(
  identity: BuildOperationIdentity,
  value: unknown,
): value is BuildOutputEvent {
  if (!value || typeof value !== "object") return false;
  const row = value as BuildOutputEvent;
  if (!identityKeys.every((key) => row[key] === identity[key])) return false;
  switch (row.type) {
    case "chunk":
      return (row.stream === "stdout" || row.stream === "stderr") && typeof row.text === "string";
    case "diagnostics":
      return (
        Array.isArray(row.diagnostics) &&
        row.diagnostics.every(
          (value) =>
            value &&
            typeof value.path === "string" &&
            typeof value.message === "string" &&
            Number.isSafeInteger(value.line) &&
            value.line > 0 &&
            (value.column == null || (Number.isSafeInteger(value.column) && value.column > 0)) &&
            ["error", "warning", "information", "hint"].includes(value.severity),
        )
      );
    case "testResults":
      return (
        !!row.results &&
        Array.isArray(row.results.tests) &&
        row.results.tests.every(
          (value) =>
            value &&
            typeof value.suite === "string" &&
            typeof value.case === "string" &&
            ["passed", "failed", "error", "skipped"].includes(value.status) &&
            (value.message == null || typeof value.message === "string") &&
            (value.path == null || typeof value.path === "string") &&
            Number.isSafeInteger(value.invocations) &&
            value.invocations >= 0,
        ) &&
        !!row.results.summary &&
        ["total", "passed", "failed", "errors", "skipped"].every((key) => {
          const value = row.results.summary[key as keyof typeof row.results.summary];
          return Number.isSafeInteger(value) && value >= 0;
        }) &&
        typeof row.results.success === "boolean"
      );
    case "terminal":
      return validTerminal(row.terminal);
    default:
      return false;
  }
}
function validTerminal(value: BuildRunTerminal): boolean {
  return (
    !!value &&
    ["succeeded", "failed", "cancelled", "failedToStart"].includes(value.kind) &&
    (value.message == null || typeof value.message === "string") &&
    (value.exitCode == null || Number.isSafeInteger(value.exitCode))
  );
}
async function abortable<T>(work: Promise<T>, signal: AbortSignal): Promise<T> {
  let abort = () => {};
  const cancelled = new Promise<never>((_resolve, reject) => {
    abort = () => reject(new Error("plugin.build.staleContext"));
    signal.addEventListener("abort", abort, { once: true });
    if (signal.aborted) abort();
  });
  try {
    return await Promise.race([work, cancelled]);
  } finally {
    signal.removeEventListener("abort", abort);
  }
}

/** Frontend handle to one native owner. No executable resolution, process
 * lifecycle, output decoding or build semantics are implemented here. A failed
 * cleanup retains this handle across panel reopening so Stop remains usable. */
export class BuildRunSession {
  readonly sessionId: string;
  readonly port: BuildOutputPort;
  #state: BuildRunState = { phase: "idle", review: null, programs: [], error: null };
  #listeners = new Set<() => void>();
  #attempt: Attempt | null = null;
  #attached = 0;
  #releaseContext: (() => void) | null = null;
  #releaseEvents: (() => void) | null = null;
  #listening: Promise<void> | null = null;
  #eventEpoch = 0;
  #finishDrain: (() => void) | null = null;
  #output: StoreApi<BuildOutputState>;
  constructor(
    readonly workspaceId: string,
    readonly pluginId: string,
    readonly buildSystemId: string,
    readonly root: string,
    private store: StoreApi<BuildSystemsState>,
    readonly native: BuildRunNative = buildRunNative,
  ) {
    this.sessionId = buildOutputSessionId(pluginId, buildSystemId, root);
    this.#output = useBuildOutputStore.getStore(workspaceId);
    this.port = {
      subscribe: async (identity, sink) =>
        native.listen(native.windowLabel(), (event) => {
          if (matchesBuildRun(identity, event)) sink(event);
        }),
      cancel: (identity) => this.cancel(identity),
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
    return !this.#attached && !this.#attempt;
  }
  #emit(patch: Partial<BuildRunState>) {
    this.#state = { ...this.#state, ...patch };
    for (const listener of this.#listeners) listener();
  }
  #instance() {
    return this.store
      .getState()
      .windows[buildSystemViewId(this.pluginId, this.buildSystemId)]?.instances.find(
        (row) => row.root === this.root,
      );
  }
  #current(attempt: Attempt) {
    const state = this.store.getState();
    const runtime = workspaceRuntimeRegistry.getWorkspace(this.workspaceId);
    return (
      !attempt.controller.signal.aborted &&
      this.#attached > 0 &&
      this.native.windowLabel() === attempt.window &&
      workspaceRuntimeRegistry.getActiveWorkspaceId() === this.workspaceId &&
      runtime?.stores.get(BUILD_SYSTEMS_STORE_KEY) === this.store &&
      runtime.status === "ready" &&
      runtime.descriptor.path === state.workspaceRoot &&
      !state.revokedPlugins[this.pluginId] &&
      (state.pluginRevocationEpochs[this.pluginId] ?? 0) === attempt.revocation &&
      state.windows[buildSystemViewId(this.pluginId, this.buildSystemId)]?.selectedRoot ===
        this.root &&
      state.requestSequence === attempt.sequence &&
      (attempt.syncing ||
        (state.generation === attempt.generation &&
          this.#instance()?.optionFingerprint === attempt.fingerprint &&
          this.#instance()?.syncDigest === attempt.syncDigest &&
          this.#instance()?.stale === attempt.stale))
    );
  }
  attach(): () => void {
    this.#attached += 1;
    if (this.#attached === 1) {
      const check = () => {
        const attempt = this.#attempt;
        if (attempt && !attempt.controller.signal.aborted && !this.#current(attempt)) {
          this.#closeEvents();
          void this.cancel().catch(() => {});
        }
        const generation = this.store.getState().generation;
        if (generation !== null) this.#output.getState().actions.invalidateGeneration(generation);
      };
      const releaseStore = this.store.subscribe(check);
      const releaseRegistry = workspaceRuntimeRegistry.subscribe(check);
      this.#releaseContext = () => {
        releaseStore();
        releaseRegistry();
      };
      const session = this.#output.getState().sessions[this.sessionId];
      if (session?.status === "running")
        void this.#listen(session.identity).catch((error) =>
          this.#output
            .getState()
            .actions.subscriptionFailed(this.sessionId, session.identity, message(error)),
        );
    }
    let released = false;
    return () => {
      if (released) return;
      released = true;
      if (--this.#attached) return;
      this.#releaseContext?.();
      this.#releaseContext = null;
      this.#closeEvents();
      if (this.#attempt) void this.cancel().catch(() => {});
    };
  }
  #closeEvents() {
    this.#finishDrain?.();
    this.#eventEpoch += 1;
    this.#releaseEvents?.();
    this.#releaseEvents = null;
    this.#listening = null;
  }
  async #listen(identity: BuildOperationIdentity): Promise<void> {
    if (this.#releaseEvents) return;
    if (this.#listening) return this.#listening;
    const epoch = this.#eventEpoch;
    const windowLabel = this.native.windowLabel();
    this.#listening = this.native
      .listen(windowLabel, (event) => {
        if (
          epoch !== this.#eventEpoch ||
          !this.#attached ||
          this.native.windowLabel() !== windowLabel ||
          !matchesBuildRun(identity, event)
        )
          return;
        const actions = this.#output.getState().actions;
        switch (event.type) {
          case "chunk":
            actions.appendChunk(this.sessionId, event, event.stream, event.text);
            break;
          case "diagnostics":
            actions.applyDiagnostics(this.sessionId, event, event.diagnostics);
            break;
          case "testResults":
            actions.applyTestResults(this.sessionId, event, event.results);
            break;
          case "terminal":
            actions.complete(this.sessionId, event, event.terminal);
            if (this.#attempt?.review?.operationId === identity.operationId) {
              const attempt = this.#attempt;
              attempt.terminalEvent = true;
              attempt.finished = true;
              if (attempt.settled) {
                if (attempt.request) this.store.getState().actions.cancelRequest(attempt.request);
                this.#attempt = null;
                this.#closeEvents();
                this.#emit({ phase: "ended", review: null, error: null });
              }
            }
            this.#finishDrain?.();
            break;
        }
      })
      .then((release) => {
        if (epoch !== this.#eventEpoch || !this.#attached) release();
        else this.#releaseEvents = release;
      });
    return this.#listening;
  }
  async #drainEvents(attempt: Attempt): Promise<void> {
    if (attempt.terminalEvent || !this.#attached) return;
    await new Promise<void>((resolve) => {
      let cancelTimer = () => {};
      const finish = () => {
        cancelTimer();
        this.#finishDrain = null;
        resolve();
      };
      this.#finishDrain = finish;
      const timeout = () => {
        if (attempt.review)
          this.#output
            .getState()
            .actions.subscriptionFailed(
              this.sessionId,
              attempt.review,
              "plugin.build.outputUnavailable",
            );
        finish();
      };
      const schedule =
        this.native.scheduleOutputDrain ??
        ((callback: () => void, milliseconds: number) => {
          const timer = setTimeout(callback, milliseconds);
          return () => clearTimeout(timer);
        });
      cancelTimer = schedule(timeout, OUTPUT_DRAIN_TIMEOUT_MS);
    });
  }
  decide(accepted: boolean) {
    const decide = this.#attempt?.decide;
    if (this.#attempt) this.#attempt.decide = null;
    if (decide) this.#emit({ review: null, phase: accepted ? "starting" : "stopping" });
    decide?.(accepted);
  }
  async start(selection: BuildRunSelection): Promise<void> {
    if (this.#attempt || this.#output.getState().sessions[this.sessionId]?.status === "running")
      return;
    const state = this.store.getState();
    const attempt: Attempt = {
      controller: new AbortController(),
      review: null,
      decide: null,
      executed: false,
      settled: false,
      finished: false,
      terminalEvent: false,
      cancellation: null,
      cleanupError: null,
      request: null,
      sequence: state.requestSequence,
      generation: state.generation,
      fingerprint: this.#instance()?.optionFingerprint,
      syncDigest: this.#instance()?.syncDigest,
      stale: this.#instance()?.stale,
      revocation: state.pluginRevocationEpochs[this.pluginId] ?? 0,
      syncing: false,
      window: this.native.windowLabel(),
    };
    this.#attempt = attempt;
    this.#emit({ phase: "preparing", error: null, review: null, programs: [] });
    const current = () => {
      if (!this.#current(attempt)) throw new Error("plugin.build.staleContext");
    };
    try {
      current();
      await abortable(this.native.save(this.workspaceId), attempt.controller.signal);
      current();
      attempt.syncing = true;
      attempt.sequence += 1;
      await abortable(
        this.native.sync(this.pluginId, this.buildSystemId, this.root),
        attempt.controller.signal,
      );
      attempt.generation = this.store.getState().generation;
      attempt.fingerprint = this.#instance()?.optionFingerprint;
      attempt.syncDigest = this.#instance()?.syncDigest;
      attempt.stale = this.#instance()?.stale;
      attempt.syncing = false;
      current();
      // Reuse the build store's busy barrier for explicit edits/model loads.
      // Passive fingerprint observations still run while busy, and invalidate
      // consent only when the source context actually changed.
      attempt.sequence += 1;
      attempt.request = this.store.getState().actions.beginRequest();
      current();
      const definition: BuildRunDefinition = await this.native.definition(
        this.pluginId,
        this.buildSystemId,
      );
      current();
      // A late prepare may allocate a native review after unmount. Always
      // retain its ID and cancel it; never race this await against disposal.
      const review = await this.native.prepare(
        this.store.getState().workspaceRoot!,
        this.pluginId,
        this.buildSystemId,
        this.root,
        selection,
      );
      attempt.review = review;
      current();
      if (
        review.pluginId !== this.pluginId ||
        review.buildSystemId !== this.buildSystemId ||
        review.root !== this.root ||
        review.workspaceRoot !== this.store.getState().workspaceRoot ||
        review.generation !== attempt.generation ||
        review.kind !== selection.kind ||
        !review.operationId
      )
        throw new Error("plugin.build.staleContext");
      this.#emit({ phase: "review", review, programs: definition.programs });
      const accepted = await new Promise<boolean>((resolve) => {
        attempt.decide = resolve;
      });
      attempt.decide = null;
      if (!accepted) return;
      current();
      const identity: BuildOperationIdentity = { ...review, title: review.title };
      if (!this.#output.getState().actions.beginOperation(this.sessionId, identity))
        throw new Error("plugin.build.busy");
      this.#closeEvents();
      await this.#listen(identity);
      current();
      // A file notification may still be in the watcher's debounce window.
      // Acquire the output listener first, then recheck the native fingerprint
      // immediately before execution. Preserve the approved snapshot rather
      // than adopting a changed model or option state. This check never
      // executes project/tool code.
      attempt.syncing = true;
      attempt.sequence += 1;
      await abortable(
        this.native.sync(this.pluginId, this.buildSystemId, this.root),
        attempt.controller.signal,
      );
      attempt.syncing = false;
      if (!attempt.stale && this.#instance()?.stale)
        throw new Error("plugin.build.modelReloadRequired");
      current();
      attempt.sequence += 1;
      attempt.request = this.store.getState().actions.beginRequest();
      current();
      this.#emit({ phase: "running", review: null });
      attempt.executed = true;
      const terminal = await this.native.execute(review.operationId);
      if (!validTerminal(terminal)) throw new Error("plugin.build.invalidOutput");
      attempt.finished = true;
      await this.#drainEvents(attempt);
      // invoke's result is authoritative after cleanup, even when the panel
      // detached before the final event. Store identity guards a replacement.
      if (
        workspaceRuntimeRegistry
          .getWorkspace(this.workspaceId)
          ?.stores.get(BUILD_SYSTEMS_STORE_KEY) === this.store
      )
        this.#output.getState().actions.complete(this.sessionId, identity, terminal);
    } catch (error) {
      if (attempt.executed && attempt.review && !attempt.finished) {
        this.#output.getState().actions.stopFailed(this.sessionId, attempt.review, message(error));
        this.#emit({ phase: "cancelFailed", review: null, error: message(error) });
        return; // An execute rejection cannot prove native cleanup.
      }
      if (!attempt.executed && !attempt.controller.signal.aborted)
        this.#emit({ phase: "failed", review: null, error: message(error) });
    } finally {
      attempt.settled = true;
      attempt.controller.abort();
      attempt.decide?.(false);
      attempt.decide = null;
      if (!attempt.executed && attempt.review && !attempt.cleanupError) {
        try {
          await this.#cancelNative(attempt);
        } catch {
          /* cancel() retained the error and native owner for retry. */
        }
      }
      const retained =
        !attempt.finished && (attempt.executed || this.#state.phase === "cancelFailed");
      if (!retained && this.#attempt === attempt) {
        if (attempt.request) this.store.getState().actions.cancelRequest(attempt.request);
        this.#attempt = null;
        this.#closeEvents();
        this.#emit({
          review: null,
          phase: this.#state.phase === "failed" ? "failed" : "ended",
          error: this.#state.phase === "failed" ? this.#state.error : null,
        });
      }
    }
  }
  async #cancelNative(attempt: Attempt): Promise<void> {
    if (!attempt.review || attempt.finished) return;
    if (attempt.cancellation) return attempt.cancellation;
    const review = attempt.review;
    attempt.cancellation = Promise.resolve()
      .then(() => this.native.cancel(review.operationId))
      .catch((error) => {
        attempt.cancellation = null;
        attempt.cleanupError = message(error);
        if (this.#attempt === attempt && !attempt.finished) {
          this.#output.getState().actions.stopFailed(this.sessionId, review, message(error));
          this.#emit({ phase: "cancelFailed", review: null, error: message(error) });
        }
        throw error;
      });
    await attempt.cancellation;
    attempt.cancellation = null;
    if (this.#attempt !== attempt) return;
    if (!attempt.executed || attempt.settled) {
      attempt.finished = true;
      // A review never executed, or execute already rejected. This native
      // cancel result confirms cleanup; a pending execute still owns its result.
      this.#output.getState().actions.complete(this.sessionId, review, { kind: "cancelled" });
      if (attempt.request) this.store.getState().actions.cancelRequest(attempt.request);
      if (this.#attempt === attempt) this.#attempt = null;
      this.#closeEvents();
      this.#emit({
        phase: this.#state.phase === "failed" ? "failed" : "ended",
        review: null,
        error: this.#state.phase === "failed" ? this.#state.error : null,
      });
    }
  }
  async cancel(identity?: BuildOperationIdentity): Promise<void> {
    const attempt = this.#attempt;
    if (
      identity &&
      (!attempt?.review || !identityKeys.every((key) => attempt.review![key] === identity[key]))
    )
      throw new Error("plugin.build.staleContext");
    if (!attempt) return;
    attempt.cleanupError = null;
    attempt.controller.abort();
    attempt.decide?.(false);
    attempt.decide = null;
    this.#emit({ phase: "stopping", review: null, error: null });
    if (attempt.review) this.#output.getState().actions.beginStop(this.sessionId, attempt.review);
    if (attempt.review) await this.#cancelNative(attempt);
  }
}

// Bounded UI handles, keyed by the actual workspace store. Native owns the
// operations; retained handles exist solely to retry a failed cleanup.
const sessions = new WeakMap<StoreApi<BuildSystemsState>, Map<string, BuildRunSession>>();
export function getBuildRunSession(
  workspaceId: string,
  pluginId: string,
  buildSystemId: string,
  root: string,
  native: BuildRunNative = buildRunNative,
): BuildRunSession {
  const store = useBuildSystemsStore.getStore(workspaceId);
  const rows = sessions.get(store) ?? new Map<string, BuildRunSession>();
  sessions.set(store, rows);
  const key = buildOutputSessionId(pluginId, buildSystemId, root);
  const existing = rows.get(key);
  if (existing) return existing;
  if (rows.size >= MAX_OUTPUT_SESSIONS) {
    const free = [...rows].find(([, session]) => session.canEvict);
    if (!free) throw new Error("plugin.build.busy");
    rows.delete(free[0]);
  }
  const session = new BuildRunSession(workspaceId, pluginId, buildSystemId, root, store, native);
  rows.set(key, session);
  return session;
}
