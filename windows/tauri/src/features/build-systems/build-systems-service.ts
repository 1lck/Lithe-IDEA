import { create, type StoreApi } from "zustand";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { invoke } from "@/platform/tauri-core";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import type {
  BuildCatalogEntry,
  BuildView,
  BuildModelReview,
  BuildModelLoadResult,
} from "./build-systems-types";
import {
  BUILD_SYSTEMS_STORE_KEY,
  buildSystemViewId,
  useBuildSystemsStore,
  type BuildSystemsState,
} from "./build-systems-store";

/**
 * Host bridge for the declarative build registry. The Rust side
 * (`plugin_host/build.rs`) owns detection, option semantics, sync digests,
 * and the trust gate; this service only forwards calls and guards late
 * responses. Every request captures its initiating workspace's store and a
 * sequence number, so a response that lands after a workspace switch, an
 * out-of-order refresh, or a plugin disable can never write another
 * workspace's store or revive a revoked window.
 */

interface FileChangeEvent {
  path: string;
  event_type: "opened" | "reloaded" | "deleted" | "rescan";
}

interface PluginLifecyclePayload {
  pluginId: string;
  active: boolean;
  operationId?: string;
}

/** Milliseconds of file-change quiet before one sync check runs. */
export const BUILD_SYNC_DEBOUNCE_MS = 500;

/** Catalog of declared build systems, for activity-rail registration. */
export const useBuildSystemsCatalogStore = create<{ entries: BuildCatalogEntry[] }>(() => ({
  entries: [],
}));

// Catalog responses are sequenced like build views: a fetch that started
// before a plugin disable must not overwrite the post-disable catalog.
let catalogSequence = 0;
let lastCatalogSequence = 0;

// The host stores one current workspace per product window. Dispatch registry
// operations in initiation order so a delayed B refresh cannot run after the
// refresh that reactivates A and silently move the native session back to B.
let registryTail: Promise<unknown> = Promise.resolve();
let activeWorkspaceId = workspaceRuntimeRegistry.getActiveWorkspaceId();
let activationEpoch = 0;

interface PendingModelLoad {
  workspaceId: string;
  pluginId: string;
  operationId: string | null;
  controller: AbortController;
  cancellation: Promise<void> | null;
  cancelError: unknown;
}
const pendingModelLoads = new Set<PendingModelLoad>();

function cancelModelLoads(predicate: (pending: PendingModelLoad) => boolean): void {
  for (const pending of pendingModelLoads) {
    if (!predicate(pending)) continue;
    // The owning load awaits the same cleanup in finally and surfaces errors.
    void requestModelCancellation(pending).catch(() => {});
  }
}

/** Cleanup failure keeps the operation available to the UI's Stop retry. */
export class BuildModelCancellationError extends Error {}

function requestModelCancellation(pending: PendingModelLoad): Promise<void> {
  pending.controller.abort();
  if (!pending.operationId) return Promise.resolve();
  if (pending.cancellation) return pending.cancellation;
  pending.cancelError = null;
  const cancellation = Promise.resolve().then(() =>
    invoke<void>("declarative_plugins_build_cancel_operation", {
      operationId: pending.operationId,
    }),
  );
  pending.cancellation = cancellation;
  void cancellation.catch((error: unknown) => {
    pending.cancelError = error;
    pending.cancellation = null;
  });
  return cancellation;
}

async function finishModelLoad(pending: PendingModelLoad, completed: boolean): Promise<void> {
  try {
    if (!completed && pending.operationId) {
      if (pending.cancelError) throw pending.cancelError;
      await requestModelCancellation(pending);
    }
  } catch (error) {
    // Cleanup failure takes priority: the UI must retain a retryable Stop
    // until native confirms that the operation has ended.
    throw new BuildModelCancellationError(failureMessage(error));
  } finally {
    // Keep cleanup discoverable until it settles so a simultaneous Stop
    // joins the owned request rather than dispatching another native cancel.
    pendingModelLoads.delete(pending);
  }
}

/** Approval owns its dialog until resolved or aborted by a workspace/lifecycle change. */
export type ApproveBuildModel = (review: BuildModelReview, signal: AbortSignal) => Promise<boolean>;

async function awaitModelApproval(
  review: BuildModelReview,
  approve: ApproveBuildModel,
  signal: AbortSignal,
): Promise<boolean> {
  if (signal.aborted) return false;
  let onAbort: () => void = () => {};
  const aborted = new Promise<boolean>((resolve) => {
    onAbort = () => resolve(false);
    signal.addEventListener("abort", onAbort, { once: true });
  });
  try {
    return await Promise.race([approve(review, signal), aborted]);
  } finally {
    signal.removeEventListener("abort", onAbort);
  }
}

/** Explicit action only. Passive detection never calls this operation. */
export async function loadBuildModel(
  pluginId: string,
  buildSystemId: string,
  root: string,
  approve: ApproveBuildModel,
  runtimeExecutables: Record<string, string> = {},
  options: { signal?: AbortSignal; onPrepared?: (review: BuildModelReview) => void } = {},
): Promise<BuildModelLoadResult | null> {
  const { store, workspaceId, workspaceRoot, isCurrent } = initiatingStore();
  if (!workspaceRoot) return null;
  const pending: PendingModelLoad = {
    workspaceId,
    pluginId,
    operationId: null,
    controller: new AbortController(),
    cancellation: null,
    cancelError: null,
  };
  pendingModelLoads.add(pending);
  let request: ReturnType<BuildSystemsState["actions"]["beginRequest"]> | null = null;
  let completed = false;
  const initial = store.getState();
  let expectedRequestSequence = initial.requestSequence;
  const generation = initial.generation;
  const revocationEpoch = initial.pluginRevocationEpochs[pluginId] ?? 0;
  const windowKey = buildSystemViewId(pluginId, buildSystemId);
  const originalWindow = initial.windows[windowKey];
  const fingerprint = originalWindow?.instances.find(
    (instance) => instance.root === root,
  )?.optionFingerprint;
  const stillCurrent = () =>
    !pending.controller.signal.aborted &&
    isCurrent() &&
    workspaceRuntimeRegistry.getWorkspace(workspaceId)?.stores.get(BUILD_SYSTEMS_STORE_KEY) ===
      store &&
    !store.getState().revokedPlugins[pluginId] &&
    (store.getState().pluginRevocationEpochs[pluginId] ?? 0) === revocationEpoch &&
    store.getState().generation === generation &&
    store.getState().requestSequence === expectedRequestSequence &&
    (!originalWindow ||
      (store.getState().windows[windowKey]?.selectedRoot === originalWindow.selectedRoot &&
        store.getState().windows[windowKey]?.instances.find((instance) => instance.root === root)
          ?.optionFingerprint === fingerprint)) &&
    (!request || store.getState().lastAppliedSequence <= request.sequence);
  const abort = () => {
    void requestModelCancellation(pending).catch(() => {});
  };
  const checkContext = () => {
    if (!completed && !stillCurrent()) abort();
  };
  const releaseStore = store.subscribe(checkContext);
  const releaseRegistry = workspaceRuntimeRegistry.subscribe(checkContext);
  options.signal?.addEventListener("abort", abort, { once: true });
  if (options.signal?.aborted) abort();
  try {
    const review = await enqueueRegistryOperation(() =>
      stillCurrent()
        ? invoke<BuildModelReview>("declarative_plugins_build_prepare_model", {
            workspaceRoot,
            pluginId,
            buildSystemId,
            root,
            runtimeExecutables: { ...runtimeExecutables },
          })
        : Promise.resolve(null),
    );
    if (!review) return null;
    pending.operationId = review.operationId;
    options.onPrepared?.(review);
    if (
      review.pluginId !== pluginId ||
      review.buildSystemId !== buildSystemId ||
      review.root !== root ||
      review.workspaceRoot !== workspaceRoot ||
      (generation !== null && review.generation !== generation)
    ) {
      throw new Error("plugin.build.staleContext");
    }
    if (
      !stillCurrent() ||
      !(await awaitModelApproval(review, approve, pending.controller.signal)) ||
      !stillCurrent()
    )
      return null;
    // Only this operation's own request may advance the captured sequence.
    // Competing edits/refreshes invalidate consent before their response lands.
    expectedRequestSequence += 1;
    request = store.getState().actions.beginRequest();
    if (!stillCurrent()) return null;
    // Execution must not occupy registryTail: refresh/revoke/close must be
    // able to reach native cancellation while a model process is running.
    const result = await invoke<BuildModelLoadResult>("declarative_plugins_build_load_model", {
      operationId: review.operationId,
    });
    if (!stillCurrent()) return null;
    if (
      result.operationId !== review.operationId ||
      result.view.workspaceRoot !== workspaceRoot ||
      result.view.generation !== review.generation
    )
      throw new Error("plugin.build.staleContext");
    completed = true;
    store.getState().actions.applyView(result.view, request);
    return result;
  } catch (error) {
    if (stillCurrent()) {
      if (request) store.getState().actions.fail(failureMessage(error), request);
      throw error;
    }
    return null;
  } finally {
    releaseStore();
    releaseRegistry();
    options.signal?.removeEventListener("abort", abort);
    pending.controller.abort();
    if (request) store.getState().actions.cancelRequest(request);
    await finishModelLoad(pending, completed);
  }
}

export async function cancelBuildModel(operationId: string): Promise<void> {
  for (const pending of pendingModelLoads) {
    if (pending.operationId === operationId) return requestModelCancellation(pending);
  }
  // The existing native contract waits for cleanup, not just acceptance.
  await invoke("declarative_plugins_build_cancel_operation", { operationId });
}

function captureActivationEpoch(): number {
  const nextId = workspaceRuntimeRegistry.getActiveWorkspaceId();
  if (nextId !== activeWorkspaceId) {
    activeWorkspaceId = nextId;
    activationEpoch += 1;
  }
  return activationEpoch;
}

function enqueueRegistryOperation<T>(operation: () => Promise<T>): Promise<T> {
  const result = registryTail.then(operation);
  registryTail = result.catch(() => {});
  return result;
}

function applyCatalog(entries: BuildCatalogEntry[], sequence: number): void {
  if (sequence < lastCatalogSequence) {
    return;
  }
  lastCatalogSequence = sequence;
  useBuildSystemsCatalogStore.setState({ entries });
}

export async function fetchBuildCatalog(): Promise<BuildCatalogEntry[]> {
  const sequence = ++catalogSequence;
  const entries = await invoke<BuildCatalogEntry[]>("declarative_plugins_build_catalog");
  applyCatalog(entries, sequence);
  return entries;
}

/** Current workspace root for this window, or null on the welcome screen. */
export function currentWorkspaceRoot(): string | null {
  return workspaceRuntimeRegistry.getActiveWorkspace()?.descriptor.path ?? null;
}

/**
 * The store of the workspace a request is initiated from. Captured before
 * the await, so a completion never writes whichever workspace happens to be
 * active by then; a closed workspace's detached store simply absorbs
 * nothing the user can see.
 */
function initiatingStore(): {
  workspaceId: string;
  store: StoreApi<BuildSystemsState>;
  workspaceRoot: string | null;
  isCurrent: () => boolean;
} {
  const workspaceId = workspaceRuntimeRegistry.getActiveWorkspaceId();
  const epoch = captureActivationEpoch();
  return {
    workspaceId,
    store: useBuildSystemsStore.getStore(workspaceId),
    workspaceRoot: currentWorkspaceRoot(),
    isCurrent: () =>
      epoch === captureActivationEpoch() &&
      workspaceId === workspaceRuntimeRegistry.getActiveWorkspaceId(),
  };
}

function failureMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/**
 * Detects build-system instances for the current workspace and applies the
 * view to the initiating workspace's store. Safe to call concurrently.
 */
export async function refreshBuildSystems(): Promise<BuildCatalogEntry[]> {
  const { workspaceId, store, workspaceRoot, isCurrent } = initiatingStore();
  cancelModelLoads((pending) => pending.workspaceId === workspaceId);
  if (!workspaceRoot) {
    store.getState().actions.reset();
    return fetchBuildCatalog();
  }
  const sequence = store.getState().actions.beginRequest();
  const [catalog] = await Promise.all([
    fetchBuildCatalog(),
    enqueueRegistryOperation(() =>
      isCurrent()
        ? invoke<BuildView>("declarative_plugins_build_refresh", { workspaceRoot })
        : Promise.resolve(null),
    )
      .then((view) => {
        if (view && isCurrent()) store.getState().actions.applyView(view, sequence);
      })
      .catch((error: unknown) => {
        if (isCurrent()) store.getState().actions.fail(failureMessage(error), sequence);
      }),
  ]);
  // A workspace removed while the request ran leaves its store detached;
  // only report the catalog for callers that are still current.
  return workspaceId === workspaceRuntimeRegistry.getActiveWorkspaceId() ? catalog : [];
}

export async function setBuildOption(
  pluginId: string,
  buildSystemId: string,
  root: string,
  optionId: string,
  value: unknown,
): Promise<void> {
  const { store, workspaceRoot, isCurrent } = initiatingStore();
  if (!workspaceRoot) {
    return;
  }
  const sequence = store.getState().actions.beginRequest();
  const view = await enqueueRegistryOperation(() =>
    isCurrent()
      ? invoke<BuildView>("declarative_plugins_build_set_option", {
          workspaceRoot,
          pluginId,
          buildSystemId,
          root,
          optionId,
          value: value ?? null,
        })
      : Promise.resolve(null),
  ).catch((error: unknown) => {
    if (isCurrent()) store.getState().actions.fail(failureMessage(error), sequence);
    throw error;
  });
  if (view && isCurrent()) store.getState().actions.applyView(view, sequence);
}

export async function syncInstance(
  pluginId: string,
  buildSystemId: string,
  root: string,
  options: { observeOnly?: boolean } = {},
): Promise<void> {
  const { workspaceId, store, workspaceRoot, isCurrent } = initiatingStore();
  if (!workspaceRoot) {
    return;
  }
  const initial = store.getState();
  const sequence = options.observeOnly
    ? { sequence: initial.requestSequence, revocationEpoch: initial.revocationEpoch }
    : initial.actions.beginRequest();
  const windowId = buildSystemViewId(pluginId, buildSystemId);
  const observationCurrent = () =>
    isCurrent() &&
    workspaceRuntimeRegistry.getWorkspace(workspaceId)?.stores.get(BUILD_SYSTEMS_STORE_KEY) ===
      store &&
    store.getState().requestSequence === sequence.sequence &&
    store.getState().revocationEpoch === sequence.revocationEpoch;
  const view = await enqueueRegistryOperation(() =>
    (options.observeOnly ? observationCurrent() : isCurrent())
      ? invoke<BuildView>("declarative_plugins_build_sync_check", {
          workspaceRoot,
          pluginId,
          buildSystemId,
          root,
        })
      : Promise.resolve(null),
  ).catch((error: unknown) => {
    if (options.observeOnly) {
      if (observationCurrent()) {
        const invalidation = store.getState().actions.beginRequest();
        store.getState().actions.fail(failureMessage(error), invalidation);
      }
    } else if (isCurrent()) store.getState().actions.fail(failureMessage(error), sequence);
    throw error;
  });
  if (!view || !isCurrent()) return;
  if (!options.observeOnly) {
    store.getState().actions.applyView(view, sequence);
    return;
  }
  if (!observationCurrent()) return;
  const current = store.getState();
  const original = current.windows[windowId]?.instances.find((row) => row.root === root);
  const updated = view.instances.find(
    (row) => row.pluginID === pluginId && row.buildSystemID === buildSystemId && row.root === root,
  );
  // Own saves and generated output also notify the file watcher. Checking a
  // fingerprint is passive; only an actual native context change invalidates
  // consent, so unchanged notifications must not cancel their own build.
  if (
    view.workspaceRoot === workspaceRoot &&
    view.generation === current.generation &&
    updated?.syncDigest === original?.syncDigest &&
    updated?.stale === original?.stale &&
    updated?.optionFingerprint === original?.optionFingerprint &&
    JSON.stringify(updated?.modelError) === JSON.stringify(original?.modelError) &&
    !!updated === !!original
  )
    return;
  const invalidation = store.getState().actions.beginRequest();
  store.getState().actions.applyView(view, invalidation);
}

/**
 * Watches workspace file changes and re-checks every instance's sync
 * fingerprint after a debounce, mirroring the macOS rule that saves within
 * the window collapse into one check. Returns the unlisten function; the
 * tool window owns this subscription and cleans it up on unmount.
 */
export async function subscribeBuildSyncWatcher(
  schedule: (callback: () => void, delayMs: number) => () => void = (callback, delayMs) => {
    const handle = setTimeout(callback, delayMs);
    return () => clearTimeout(handle);
  },
): Promise<UnlistenFn> {
  let pending: (() => void) | null = null;
  let timer: (() => void) | null = null;
  const runChecks = () => {
    pending = null;
    if (!currentWorkspaceRoot()) {
      return;
    }
    // Read the active workspace's store at fire time; a workspace switch
    // during the debounce checks the new workspace's instances only.
    const state = useBuildSystemsStore.getState();
    if (!state.workspaceRoot || state.generation === null) {
      return;
    }
    for (const window of Object.values(state.windows)) {
      for (const instance of window.instances) {
        syncInstance(instance.pluginID, instance.buildSystemID, instance.root, {
          observeOnly: true,
        }).catch(() => {
          // A failed sync (workspace mid-switch, plugin disabled) keeps the
          // last state; the next change or manual refresh retries.
        });
      }
    }
  };
  const unlisten = await listen<FileChangeEvent>("ln", (event) => {
    if (!currentWorkspaceRoot()) {
      return;
    }
    pending = runChecks;
    timer?.();
    timer = schedule(() => {
      timer = null;
      pending?.();
    }, BUILD_SYNC_DEBOUNCE_MS);
  });
  return () => {
    timer?.();
    pending = null;
    unlisten();
  };
}

/** Refcounted per-mount sync watcher shared by every build tool window. */
let watcherConsumers = 0;
let watcherUnlisten: UnlistenFn | null = null;
let watcherAcquisition: Promise<void> | null = null;

export async function acquireBuildSyncWatcher(): Promise<() => void> {
  watcherConsumers += 1;
  if (!watcherUnlisten && !watcherAcquisition) {
    watcherAcquisition = subscribeBuildSyncWatcher().then((unlisten) => {
      watcherUnlisten = unlisten;
      watcherAcquisition = null;
    });
  }
  await watcherAcquisition;
  return () => {
    watcherConsumers -= 1;
    if (watcherConsumers === 0 && watcherUnlisten) {
      watcherUnlisten();
      watcherUnlisten = null;
    }
  };
}

/**
 * Revokes one plugin everywhere: its catalog entries, every instantiated
 * workspace store's window state, and the native registry sessions. The
 * frontend lifecycle listener calls this when a plugin is disabled,
 * replaced, or uninstalled.
 */
async function revokePlugin(pluginId: string): Promise<void> {
  cancelModelLoads((pending) => pending.pluginId === pluginId);
  const sequence = ++catalogSequence;
  applyCatalog(
    useBuildSystemsCatalogStore.getState().entries.filter((entry) => entry.pluginId !== pluginId),
    sequence,
  );
  for (const store of workspaceRuntimeRegistry.getExistingStores<BuildSystemsState>(
    BUILD_SYSTEMS_STORE_KEY,
  )) {
    store.getState().actions.dropPlugin(pluginId);
  }
  await enqueueRegistryOperation(() =>
    invoke("declarative_plugins_build_plugins_changed", { pluginId }),
  ).catch(() => {
    // The native revoke is best-effort from the listener; every later
    // command re-checks the package against the trust gate anyway.
  });
}

function allowPluginEverywhere(pluginId: string): void {
  for (const store of workspaceRuntimeRegistry.getExistingStores<BuildSystemsState>(
    BUILD_SYSTEMS_STORE_KEY,
  )) {
    store.getState().actions.allowPlugin(pluginId);
  }
}

/** Refcounted plugin-lifecycle listener shared by the bootstrap runtime. */
let lifecycleConsumers = 0;
let lifecycleUnlisten: UnlistenFn | null = null;
let lifecycleAcquisition: Promise<void> | null = null;

async function acquireLifecycleListener(): Promise<() => void> {
  lifecycleConsumers += 1;
  if (!lifecycleUnlisten && !lifecycleAcquisition) {
    lifecycleAcquisition = listen<PluginLifecyclePayload>(
      "declarative-plugin-lifecycle",
      ({ payload }) => {
        if (payload.active) {
          allowPluginEverywhere(payload.pluginId);
          void refreshBuildSystems().catch(() => {});
          return;
        }
        void revokePlugin(payload.pluginId);
      },
      // Same targeting rule as the other declarative listeners: only this
      // product window drains its own lifecycle events.
      { target: { kind: "Window", label: getCurrentWindow().label } },
    ).then((unlisten) => {
      lifecycleUnlisten = unlisten;
      lifecycleAcquisition = null;
    });
  }
  await lifecycleAcquisition;
  return () => {
    lifecycleConsumers -= 1;
    if (lifecycleConsumers === 0 && lifecycleUnlisten) {
      lifecycleUnlisten();
      lifecycleUnlisten = null;
    }
  };
}

/** Cleanup registered by the bootstrap runtime; see startBuildSystemsRuntime. */
export let cleanupBuildSystemsRuntime: (() => void) | null = null;

/**
 * Keeps the window-owned native registry aligned with the active workspace.
 * Stores retain their ready views across tab switches, but the Rust registry
 * intentionally has only one current workspace per window, so every actual
 * activation must re-detect once even when the returning store is ready.
 */
function subscribeWorkspaceActivations(): () => void {
  let observedWorkspaceId = workspaceRuntimeRegistry.getActiveWorkspaceId();
  return workspaceRuntimeRegistry.subscribe(() => {
    const nextWorkspaceId = workspaceRuntimeRegistry.getActiveWorkspaceId();
    if (nextWorkspaceId === observedWorkspaceId) {
      return;
    }
    cancelModelLoads((pending) => pending.workspaceId === observedWorkspaceId);
    observedWorkspaceId = nextWorkspaceId;
    captureActivationEpoch();
    void refreshBuildSystems().catch(() => {});
  });
}

/**
 * Bootstrap entry: registers the plugin-lifecycle listener (catalog and
 * registry revocation) and warms the catalog. Returns the cleanup; the page
 * also cleans up on hide, so a destroyed window never keeps the listener.
 */
export async function startBuildSystemsRuntime(): Promise<() => void> {
  const releaseLifecycle = await acquireLifecycleListener();
  const releaseWorkspaceActivations = subscribeWorkspaceActivations();
  // `window` is absent under the bun test runner; the cleanup stays
  // available for callers there.
  const hasWindow = typeof window !== "undefined";
  let cleaned = false;
  const cleanup = () => {
    if (cleaned) {
      return;
    }
    cleaned = true;
    cancelModelLoads(() => true);
    if (hasWindow) {
      window.removeEventListener("pagehide", onPageHide);
    }
    releaseWorkspaceActivations();
    releaseLifecycle();
    if (cleanupBuildSystemsRuntime === cleanup) {
      cleanupBuildSystemsRuntime = null;
    }
  };
  const onPageHide = () => cleanup();
  if (hasWindow) {
    window.addEventListener("pagehide", onPageHide, { once: true });
  }
  cleanupBuildSystemsRuntime = cleanup;
  // Align the native window session on startup as well as warming the
  // catalog. The welcome workspace path still skips native detection.
  void refreshBuildSystems().catch(() => {});
  return cleanup;
}
