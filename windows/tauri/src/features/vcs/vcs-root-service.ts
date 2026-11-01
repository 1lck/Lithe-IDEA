import { invoke } from "@/platform/tauri-core";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { subscribePluginActivity } from "@/features/plugins/declarative-plugin-lifecycle";
import type { WorkspaceRuntime } from "@/features/workspace/types/workspace-runtime.types";
import { VcsRootController } from "./vcs-root-controller";
import type { VcsRootPort, VcsInvalidation } from "./vcs-root-types";

const ROOT_REFRESH_DEBOUNCE_MS = 750;
const MAX_RETIRED_CONTROLLERS = 16;
const native: VcsRootPort = {
  subscribe: async (_scope, changed) => {
    const { listen } = await import("@tauri-apps/api/event");
    return listen<VcsInvalidation>("vcs-roots-invalidated", (event) => changed(event.payload));
  },
  debounce: (callback) => {
    const timer = setTimeout(callback, ROOT_REFRESH_DEBOUNCE_MS);
    return () => clearTimeout(timer);
  },
  saveMapping: (scope, generation, revision, id, vcs) =>
    invoke("declarative_plugins_vcs_save_mapping", { scope, generation, revision, id, vcs }),
  detect: (scope) => invoke("declarative_plugins_vcs_detect", { scope }),
  owners: (scope, generation, paths) =>
    invoke("declarative_plugins_vcs_owners", { scope, generation, paths }),
  close: (scope) => invoke("declarative_plugins_vcs_close", { scope }),
  status: (scope, generation, rootId, requestId) =>
    invoke("declarative_plugins_vcs_status", { scope, generation, rootId, requestId }),
  write: (scope, generation, rootId, requestId, statusId, action) =>
    invoke("declarative_plugins_vcs_write", {
      scope,
      generation,
      rootId,
      requestId,
      statusId,
      action,
    }),
  writeDeadline: (callback) => {
    const timer = setTimeout(callback, 720_000);
    return () => clearTimeout(timer);
  },
  query: (scope, generation, rootId, requestId, query) =>
    invoke("declarative_plugins_vcs_query", { scope, generation, rootId, requestId, query }),
  cancelStatus: (scope, requestId) =>
    invoke("declarative_plugins_vcs_cancel_status", { scope, requestId }),
  statusDeadline: (callback) => {
    const timer = setTimeout(callback, 90_000);
    return () => clearTimeout(timer);
  },
  deadline: (callback) => {
    const timer = setTimeout(callback, 16_000);
    return () => clearTimeout(timer);
  },
};
const roots = new Map<string, { runtime: WorkspaceRuntime; controller: VcsRootController }>();
// A retired controller is never reusable, but its failed native cleanup owner
// remains reachable. A replacement's first discovery drains these exact scopes.
const retiring = new Map<string, Map<VcsRootController, Promise<void> | null>>();
let stopObserving: (() => void) | null = null;
function observe() {
  if (stopObserving) return;
  const stopWorkspace = workspaceRuntimeRegistry.subscribe(() => {
    for (const [id, entry] of roots) {
      const runtime = workspaceRuntimeRegistry.getWorkspace(id);
      if (
        runtime !== entry.runtime ||
        runtime.descriptor.path !== entry.controller.scope.workspaceRoot
      ) {
        void closeWorkspaceVcsRoots(id).catch((error) =>
          console.warn("VCS root cleanup failed", error),
        );
      } else if (runtime.status !== "ready") {
        void closeWorkspaceVcsRoots(id).catch((error) =>
          console.warn("VCS root cleanup failed", error),
        );
      }
    }
  });
  const stopPlugins = subscribePluginActivity(() => {
    for (const entry of roots.values()) {
      entry.controller.invalidate();
      if (entry.runtime.status === "ready") void entry.controller.refresh();
    }
  });
  stopObserving = () => {
    stopWorkspace();
    stopPlugins();
    stopObserving = null;
  };
}
/** The owning workspace store/selector consumes this independent projection;
 * Git's activeRepoPath and Git-only actions are never replaced with plugin roots. */
export function workspaceVcsRoots(workspaceId: string): VcsRootController | null {
  const runtime = workspaceRuntimeRegistry.getWorkspace(workspaceId);
  const path = runtime?.descriptor.path;
  if (!runtime || runtime.status !== "ready" || !path || /^(wsl|remote):\/\//u.test(path))
    return null;
  const existing = roots.get(workspaceId);
  if (existing?.runtime === runtime && existing.controller.scope.workspaceRoot === path)
    return existing.controller;
  if (existing)
    void closeWorkspaceVcsRoots(workspaceId).catch((error) =>
      console.warn("VCS root cleanup failed", error),
    );
  if ((retiring.get(workspaceId)?.size ?? 0) >= MAX_RETIRED_CONTROLLERS) return null;
  const controller = new VcsRootController(
    { workspaceId, workspaceRoot: path, incarnation: crypto.randomUUID() },
    {
      ...native,
      detect: async (scope) => {
        await drainRetired(workspaceId);
        return native.detect(scope);
      },
    },
  );
  roots.set(workspaceId, { runtime, controller });
  observe();
  return controller;
}
export async function closeWorkspaceVcsRoots(workspaceId: string): Promise<void> {
  const entry = roots.get(workspaceId);
  if (entry) {
    roots.delete(workspaceId);
    let group = retiring.get(workspaceId);
    if (!group) {
      group = new Map();
      retiring.set(workspaceId, group);
    }
    group.set(entry.controller, null);
  }
  await drainRetired(workspaceId);
}
async function drainRetired(workspaceId: string): Promise<void> {
  const group = retiring.get(workspaceId);
  if (!group) return;
  const attempts = [...group.keys()].map((controller) => {
    let pending = group.get(controller);
    if (!pending) {
      pending = controller.close().then(
        () => {
          group.delete(controller);
        },
        (error) => {
          group.set(controller, null);
          throw error;
        },
      );
      group.set(controller, pending);
    }
    return pending;
  });
  const outcomes = await Promise.allSettled(attempts);
  if (!group.size && retiring.get(workspaceId) === group) retiring.delete(workspaceId);
  if (!roots.size && !retiring.size) stopObserving?.();
  const failed = outcomes.find((outcome) => outcome.status === "rejected");
  if (failed?.status === "rejected") throw failed.reason;
}
