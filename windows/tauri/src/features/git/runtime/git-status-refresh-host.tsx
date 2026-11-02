import { useEffect, useRef } from "react";
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
import { subscribeToIndexingChanges } from "@/features/file-explorer/stores/workspace-indexing";

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
  // Selection changes recreate the subscription effect; keep queued discovery
  // owned by the workspace rather than by its cancelled debounce timer.
  const rediscover = useRef(false);

  useEffect(() => {
    rediscover.current = false;
    if (!ready) return;
    void repositoryActions.syncWorkspaceRepositories(
      normalizeWorkspaceFolders(rootPath, folders).map((folder) => folder.path),
      { force: true },
    );
  }, [ready, rootPath, folders, repositoryActions]);

  useEffect(() => {
    if (!rootPath || !ready) return;
    let current = true;
    let timer: ReturnType<typeof setTimeout> | null = null;
    let running = false;
    let pending = false;
    const roots = normalizeWorkspaceFolders(rootPath, folders).map((folder) => folder.path);
    const repositoryStore = useRepositoryStore.getStore(workspaceId);
    const refresh = async () => {
      if (!current || !workspaceRuntimeRegistry.isWorkspaceReady(workspaceId)) return;
      if (running) { pending = true; return; }
      running = true;
      try {
        do {
          pending = false;
          if (rediscover.current) {
            rediscover.current = false;
            await repositoryActions.refreshWorkspaceRepositories();
          }
          if (!current || !workspaceRuntimeRegistry.isWorkspaceReady(workspaceId)) return;
          const repositories = repositoryStore.getState();
          if (repositories.error || repositories.isDiscovering) {
            if (pending) continue;
            return;
          }
          const paths = repositories.availableRepoPaths;
          await actions.refreshRepositoryStatuses([...paths, rootPath], paths);
        } while (pending && current);
      } catch (error) {
        if (current) console.error("Failed to refresh workspace Git status:", error);
      } finally {
        running = false;
      }
    };
    const schedule = (discover = false) => {
      rediscover.current ||= discover;
      if (discover) {
        actions.invalidateRepositoryReads();
        repositoryActions.invalidateWorkspaceRepositories();
      }
      if (timer !== null) scheduler.clearTimer(timer);
      timer = scheduler.setTimer(() => { timer = null; void refresh(); }, 100);
    };
    if (activeRepoPath || rediscover.current) void refresh();
    // A discovery started by an earlier subscription may finish after a
    // selection change. Its owner is gone, but this workspace still needs status.
    const unsubscribeDiscovery = repositoryStore.subscribe((state, previous) => {
      if (previous.isDiscovering && !state.isDiscovering && !state.error && !running) {
        void refresh();
      }
    });
    const unsubscribe = subscribeToGitChanges((change) => {
      if (![...roots, ...repoPaths].some((path) => isGitChangeRelevant(change, path))) return;
      schedule(change.repositoryRootsMayHaveChanged || change.scopes?.includes("repository") ||
        /(^|[/\\])\.gitignore$/.test(change.filePath ?? ""));
    });
    const unsubscribePreferences = subscribeToIndexingChanges(roots, () => schedule(true), true);
    const externalFile = (event: Event) => {
      const { path, event_type: kind } = (event as CustomEvent<{path: string; event_type: string}>).detail;
      if (!roots.some((root) => isGitChangeRelevant({repoPath: path}, root))) return;
      if (kind === "rescan" || /(^|[/\\])\.(gitignore$|git([/\\]|$))/.test(path)) schedule(true);
    };
    const focus = () => schedule(true);
    window.addEventListener("file-external-change", externalFile);
    window.addEventListener("focus", focus);
    return () => {
      current = false;
      unsubscribe(); unsubscribePreferences(); unsubscribeDiscovery();
      window.removeEventListener("file-external-change", externalFile);
      window.removeEventListener("focus", focus);
      if (timer !== null) scheduler.clearTimer(timer);
    };
  }, [ready, workspaceId, rootPath, folders, activeRepoPath, repoPaths, actions, repositoryActions, scheduler]);
  return null;
}
