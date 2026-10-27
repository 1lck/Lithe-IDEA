import { invoke } from "@/platform/tauri-core";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { subscribePluginActivity } from "@/features/plugins/declarative-plugin-lifecycle";
import type { WorkspaceRuntime } from "@/features/workspace/types/workspace-runtime.types";
import { VcsRootController } from "./vcs-root-controller";
import type { VcsRootPort } from "./vcs-root-types";

const native: VcsRootPort = {
  detect: (scope) => invoke("declarative_plugins_vcs_detect", { scope }),
  owners: (scope, generation, paths) =>
    invoke("declarative_plugins_vcs_owners", { scope, generation, paths }),
  close: (scope) => invoke("declarative_plugins_vcs_close", { scope }),
  status: (scope, generation, rootId, requestId) =>
    invoke("declarative_plugins_vcs_status", { scope, generation, rootId, requestId }),
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
      } else if (runtime.status !== "ready") entry.controller.invalidate();
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
  const controller = new VcsRootController(
    { workspaceId, workspaceRoot: path, incarnation: crypto.randomUUID() },
    native,
  );
  roots.set(workspaceId, { runtime, controller });
  observe();
  return controller;
}
export async function closeWorkspaceVcsRoots(workspaceId: string): Promise<void> {
  const entry = roots.get(workspaceId);
  if (!entry) return;
  await entry.controller.close();
  if (roots.get(workspaceId) === entry) roots.delete(workspaceId);
  if (!roots.size) stopObserving?.();
}
