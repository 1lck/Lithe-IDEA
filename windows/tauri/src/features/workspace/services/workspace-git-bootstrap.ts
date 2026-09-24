import { normalizeWorkspaceFolders } from "@/features/file-system/controllers/workspace-session";
import { discoverWorkspaceRepositories } from "@/features/git/api/git-repo-api";
import { getWorkspaceRootGitStatus } from "@/features/git/api/git-status-api";
import { useGitStore } from "@/features/git/stores/git.store";
import { frontendTrace } from "@/utils/frontend-trace";
import { workspaceRuntimeRegistry } from "../runtime/workspace-runtime-registry";
import {
  workspaceScopeMatchesRoot,
  type WorkspaceLaunchScope,
} from "../types/workspace-launch-scope";
import type { WorkspaceRuntime } from "../types/workspace-runtime.types";
import { bootstrapWorkspaceGit } from "./workspace-startup-priority";

type BootstrapOutcome = "published" | "superseded" | "failed" | "skipped";
interface WorkspaceGitBootstrap {
  rootsKey: string;
  settled: boolean;
  task: Promise<BootstrapOutcome>;
}

// Completed work belongs to the runtime, so closing and reopening a workspace
// cannot reuse its old bootstrap or retain it through a process-wide path cache.
const bootstraps = new WeakMap<WorkspaceRuntime, WorkspaceGitBootstrap>();

export async function ensureWorkspaceGitBootstrap(
  scope: WorkspaceLaunchScope,
  options: { refresh?: boolean } = {},
): Promise<BootstrapOutcome> {
  const runtime = workspaceRuntimeRegistry.getWorkspace(scope.workspaceId);
  if (!runtime || scope.root.startsWith("remote://") || scope.root.startsWith("wsl://")) {
    return "skipped";
  }

  // The file-system store also invokes this service after session restoration.
  // Resolve it lazily to keep module initialization free of that dependency cycle.
  const { useFileSystemStore } = await import("@/features/file-system/stores/file-system.store");
  if (workspaceRuntimeRegistry.getWorkspace(scope.workspaceId) !== runtime) return "superseded";
  const fileSystemStore = useFileSystemStore.getStore(scope.workspaceId);
  const state = fileSystemStore.getState();
  if (!state.rootFolderPath) return "skipped";
  if (!workspaceScopeMatchesRoot(scope, state.rootFolderPath)) return "superseded";
  const rootPaths = normalizeWorkspaceFolders(state.rootFolderPath, state.workspaceFolders)
    .map((folder) => folder.path);
  const rootsKey = JSON.stringify(rootPaths);
  const existing = bootstraps.get(runtime);
  if (existing?.rootsKey === rootsKey && (!options.refresh || !existing.settled)) {
    return existing.task;
  }

  const gitStore = useGitStore.getStore(scope.workspaceId);
  const bootstrap: WorkspaceGitBootstrap = {
    rootsKey,
    settled: false,
    task: Promise.resolve("superseded"),
  };
  const isCurrent = () => {
    const current = fileSystemStore.getState();
    return workspaceRuntimeRegistry.getWorkspace(scope.workspaceId) === runtime &&
      bootstraps.get(runtime) === bootstrap &&
      workspaceScopeMatchesRoot(scope, current.rootFolderPath) &&
      JSON.stringify(normalizeWorkspaceFolders(current.rootFolderPath, current.workspaceFolders)
        .map((folder) => folder.path)) === rootsKey;
  };
  bootstraps.set(runtime, bootstrap);
  const startedAt = performance.now();
  const traceContext = { workspaceId: scope.workspaceId, rootCount: rootPaths.length };
  frontendTrace("info", "workspace-open", "gitBootstrap:start", traceContext);
  bootstrap.task = bootstrapWorkspaceGit({
    workspaceRootPaths: rootPaths,
    discoverRepositories: discoverWorkspaceRepositories,
    loadStatus: (repoPaths) => getWorkspaceRootGitStatus(scope.root, repoPaths),
    isCurrent,
    publishStatus: (status) => gitStore.getState().actions.setWorkspaceGitStatus(status, scope.root),
  }).then((outcome) => {
    frontendTrace("info", "workspace-open", `gitBootstrap:${outcome}`, {
      ...traceContext, durationMs: Math.round(performance.now() - startedAt),
    });
    return outcome;
  }).catch((error: unknown): BootstrapOutcome => {
    if (!isCurrent()) return "superseded";
    gitStore.getState().actions.setWorkspaceGitStatus(null, scope.root);
    frontendTrace("error", "workspace-open", "gitBootstrap:failed", {
      ...traceContext, durationMs: Math.round(performance.now() - startedAt),
    });
    console.error("Failed to bootstrap workspace Git before Java:", error);
    // Git failure must not permanently disable Java language services.
    return "failed";
  }).finally(() => {
    bootstrap.settled = true;
    // A root set can be removed and later re-added on the same runtime. Its
    // superseded attempt must not become a permanently cached launch veto.
    if (bootstraps.get(runtime) === bootstrap && !isCurrent()) {
      bootstraps.delete(runtime);
    }
  });
  return bootstrap.task;
}
