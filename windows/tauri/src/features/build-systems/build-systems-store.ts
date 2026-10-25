import { create } from "zustand";
import { createWorkspaceScopedStore } from "@/features/workspace/stores/create-workspace-scoped-store";
import type { BuildIssue, BuildView, BuildWindowState } from "./build-systems-types";

export const BUILD_SYSTEMS_STORE_KEY = "build-systems";

export interface BuildRequestVersion {
  sequence: number;
  /** Store-wide revocation clock captured before the native call starts. */
  revocationEpoch: number;
}

/**
 * Display state for the declarative build tool windows, scoped to one
 * workspace. The Rust registry owns the build facts; this store only
 * mirrors the latest view and the user's instance selection.
 */

export interface BuildSystemsState {
  status: "idle" | "loading" | "ready" | "failed";
  generation: number | null;
  workspaceRoot: string | null;
  error: string | null;
  issues: BuildIssue[];
  windows: Record<string, BuildWindowState>;
  /**
   * Monotonic sequence of requests this workspace's store issued. Responses
   * carry the sequence they were initiated with; anything older than the
   * last applied sequence is a late or out-of-order response and is dropped,
   * whether it reports success or failure.
   */
  requestSequence: number;
  lastAppliedSequence: number;
  /** Monotonic clock used to identify requests that predate a plugin revoke. */
  revocationEpoch: number;
  /** Last revoke clock per plugin, retained across a later re-enable. */
  pluginRevocationEpochs: Record<string, number>;
  /** Plugins that remain revoked until an active lifecycle event arrives. */
  revokedPlugins: Record<string, true>;
  actions: {
    /** Marks a request in flight and returns its sequence and revoke clock. */
    beginRequest: () => BuildRequestVersion;
    applyView: (view: BuildView, request: BuildRequestVersion) => void;
    fail: (message: string, request: BuildRequestVersion) => void;
    cancelRequest: (request: BuildRequestVersion) => void;
    selectInstance: (viewId: string, root: string) => void;
    /** Drops one disabled plugin and invalidates requests started before it. */
    dropPlugin: (pluginId: string) => void;
    /** Allows post-enable requests to return the plugin again. */
    allowPlugin: (pluginId: string) => void;
    reset: () => void;
  };
}

/** Tool-window view id of one plugin build system. */
export function buildSystemViewId(pluginId: string, buildSystemId: string): string {
  return `build-system:${pluginId}:${buildSystemId}`;
}

export function parseBuildSystemViewId(
  view: string,
): { pluginId: string; buildSystemId: string } | null {
  if (!view.startsWith("build-system:")) {
    return null;
  }
  const rest = view.slice("build-system:".length);
  const separator = rest.indexOf(":");
  if (separator <= 0 || separator === rest.length - 1) {
    return null;
  }
  return {
    pluginId: rest.slice(0, separator),
    buildSystemId: rest.slice(separator + 1),
  };
}

function applyViewToState(
  state: BuildSystemsState,
  view: BuildView,
  request: BuildRequestVersion,
): Partial<BuildSystemsState> {
  // Late responses never win: an out-of-order sequence, a changed workspace
  // root, or an older generation all mean the store already moved on.
  if (request.sequence < state.lastAppliedSequence) {
    return {};
  }
  if (state.workspaceRoot && view.workspaceRoot !== state.workspaceRoot) {
    return {};
  }
  if (state.generation !== null && view.generation < state.generation) {
    return {};
  }

  const wasRevokedAfterRequest = (pluginId: string | undefined) =>
    !!pluginId &&
    (state.revokedPlugins[pluginId] === true ||
      (state.pluginRevocationEpochs[pluginId] ?? 0) > request.revocationEpoch);
  const grouped = new Map<string, BuildWindowState>();
  for (const instance of view.instances) {
    // A request that started before disable may still carry that plugin in
    // its native snapshot. Drop only the revoked owner so unrelated plugin
    // state in the same complete view remains legal and can still update.
    if (wasRevokedAfterRequest(instance.pluginID)) {
      continue;
    }
    const viewId = buildSystemViewId(instance.pluginID, instance.buildSystemID);
    const existing = grouped.get(viewId);
    if (existing) {
      existing.instances.push(instance);
      continue;
    }
    grouped.set(viewId, {
      pluginId: instance.pluginID,
      buildSystemId: instance.buildSystemID,
      displayName: instance.displayName,
      instances: [instance],
      selectedRoot: null,
    });
  }
  // Preserve the user's instance selection when the instance is still there;
  // otherwise fall back to the first instance deterministically.
  const windows: Record<string, BuildWindowState> = {};
  for (const [viewId, next] of grouped) {
    const previous = state.windows[viewId];
    const stillSelected =
      previous?.selectedRoot &&
      next.instances.some((instance) => instance.root === previous.selectedRoot);
    next.selectedRoot = stillSelected ? previous!.selectedRoot : (next.instances[0]?.root ?? null);
    windows[viewId] = next;
  }

  return {
    status: "ready",
    generation: view.generation,
    workspaceRoot: view.workspaceRoot,
    error: null,
    issues: view.issues.filter(
      (issue) => !wasRevokedAfterRequest(issue.pluginID) && !wasRevokedAfterRequest(issue.by),
    ),
    windows,
    lastAppliedSequence: request.sequence,
  };
}

const createBuildSystemsStore = () =>
  create<BuildSystemsState>()((set, get) => ({
    status: "idle",
    generation: null,
    workspaceRoot: null,
    error: null,
    issues: [],
    windows: {},
    requestSequence: 0,
    lastAppliedSequence: 0,
    revocationEpoch: 0,
    pluginRevocationEpochs: {},
    revokedPlugins: {},
    actions: {
      beginRequest: () => {
        const sequence = get().requestSequence + 1;
        set((state) => ({ requestSequence: sequence, status: "loading" }));
        return { sequence, revocationEpoch: get().revocationEpoch };
      },
      applyView: (view, request) => set((state) => applyViewToState(state, view, request)),
      fail: (message, request) =>
        set((state) => {
          // A failure only lands when no newer response already applied;
          // otherwise the late error would clobber fresher state. A request
          // crossing any revoke cannot name a safe owner, so its failure is
          // stale as well.
          if (
            request.sequence < state.lastAppliedSequence ||
            request.revocationEpoch !== state.revocationEpoch
          ) {
            return state;
          }
          return {
            status: "failed",
            error: message,
            lastAppliedSequence: request.sequence,
          };
        }),
      cancelRequest: (request) =>
        set((state) =>
          state.status === "loading" &&
          request.sequence === state.requestSequence &&
          request.revocationEpoch === state.revocationEpoch
            ? { status: state.workspaceRoot ? "ready" : "idle" }
            : state,
        ),
      dropPlugin: (pluginId) =>
        set((state) => {
          const revocationEpoch = state.revocationEpoch + 1;
          const windows = Object.fromEntries(
            Object.entries(state.windows).filter(([, target]) => target.pluginId !== pluginId),
          );
          const issues = state.issues.filter((issue) => issue.pluginID !== pluginId);
          return {
            status: "ready",
            error: null,
            windows,
            issues,
            revocationEpoch,
            pluginRevocationEpochs: {
              ...state.pluginRevocationEpochs,
              [pluginId]: revocationEpoch,
            },
            revokedPlugins: { ...state.revokedPlugins, [pluginId]: true },
          };
        }),
      allowPlugin: (pluginId) =>
        set((state) => {
          if (!state.revokedPlugins[pluginId]) {
            return state;
          }
          const revokedPlugins = { ...state.revokedPlugins };
          delete revokedPlugins[pluginId];
          return { revokedPlugins };
        }),
      selectInstance: (viewId, root) =>
        set((state) => {
          const target = state.windows[viewId];
          if (!target || !target.instances.some((instance) => instance.root === root)) {
            return state;
          }
          return {
            windows: {
              ...state.windows,
              [viewId]: { ...target, selectedRoot: root },
            },
          };
        }),
      reset: () =>
        set({
          status: "idle",
          generation: null,
          workspaceRoot: null,
          error: null,
          issues: [],
          windows: {},
          requestSequence: 0,
          lastAppliedSequence: 0,
          revocationEpoch: 0,
          pluginRevocationEpochs: {},
          revokedPlugins: {},
        }),
    },
  }));

export const useBuildSystemsStore = createWorkspaceScopedStore(
  BUILD_SYSTEMS_STORE_KEY,
  createBuildSystemsStore,
);
