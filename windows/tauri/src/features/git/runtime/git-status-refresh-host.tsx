import { useEffect } from "react";
import { normalizeWorkspaceFolders } from "@/features/file-system/controllers/workspace-session";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import {
  useActiveWorkspaceId,
  useWorkspaceReady,
} from "@/features/workspace/stores/create-workspace-scoped-store";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { isGitChangeRelevant, subscribeToGitChanges } from "../events/git-events";
import { useRepositoryStore } from "../stores/git-repository.store";
import { useGitStore } from "../stores/git.store";

export interface GitStatusRefreshScheduler {
  setTimer: (callback: () => void, delay: number) => ReturnType<typeof setTimeout>;
  clearTimer: (timer: ReturnType<typeof setTimeout>) => void;
}

const defaultScheduler: GitStatusRefreshScheduler = {
  setTimer: (callback, delay) => setTimeout(callback, delay),
  clearTimer: (timer) => clearTimeout(timer),
};

/** Workspace-owned status refreshes remain active while the Commit panel is closed. */
export function GitStatusRefreshHost({
  scheduler = defaultScheduler,
}: {
  scheduler?: GitStatusRefreshScheduler;
}) {
  const workspaceId = useActiveWorkspaceId();
  const ready = useWorkspaceReady(workspaceId);
  const rootPath = useFileSystemStore((state) => state.rootFolderPath);
  const folders = useFileSystemStore((state) => state.workspaceFolders);
  const activeRepoPath = useRepositoryStore((state) => state.activeRepoPath);
  const repoPaths = useRepositoryStore((state) => state.availableRepoPaths);
  const repositoryActions = useRepositoryStore((state) => state.actions);
  const actions = useGitStore((state) => state.actions);

  useEffect(() => {
    if (!ready) return;
    void repositoryActions.syncWorkspaceRepositories(
      normalizeWorkspaceFolders(rootPath, folders).map((folder) => folder.path),
    );
  }, [ready, rootPath, folders, repositoryActions]);

  useEffect(() => {
    if (!rootPath || !ready) return;
    let current = true;
    let timer: ReturnType<typeof setTimeout> | null = null;
    const refresh = async () => {
      if (!current || !workspaceRuntimeRegistry.isWorkspaceReady(workspaceId)) return;
      const paths = repoPaths.length ? repoPaths : useGitStore.getState().statusRepoPaths;
      try {
        await actions.refreshRepositoryStatuses([...paths, rootPath], paths);
      } catch (error) {
        if (current) console.error("Failed to refresh workspace Git status:", error);
      }
    };
    if (activeRepoPath) void refresh();
    const unsubscribe = subscribeToGitChanges((change) => {
      if (![rootPath, ...repoPaths].some((path) => isGitChangeRelevant(change, path))) return;
      if (timer !== null) scheduler.clearTimer(timer);
      timer = scheduler.setTimer(() => {
        timer = null;
        void refresh();
      }, 100);
    });
    return () => {
      current = false;
      unsubscribe();
      if (timer !== null) scheduler.clearTimer(timer);
    };
  }, [ready, workspaceId, rootPath, activeRepoPath, repoPaths, actions, scheduler]);
  return null;
}
