import { useCallback, useEffect, useRef, useState } from "react";
import { normalizeWorkspaceFolders } from "@/features/file-system/controllers/workspace-session";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { getBranches } from "../api/git-branches-api";
import { getGitHistory } from "../api/git-commits-api";
import { getOperationState } from "../api/git-integration-api";
import { clearRepositoryDiscoveryCache } from "../api/git-repo-api";
import { getStashes } from "../api/git-stash-api";
import { getWorkspaceGitStatus } from "../api/git-status-api";
import {
  isGitChangeRelevant,
  isPassiveGitChange,
  subscribeToGitChanges,
  type GitChangeScope,
} from "../events/git-events";
import { useRepositoryStore } from "../stores/git-repository.store";
import { useGitStore } from "../stores/git.store";

interface GitDataControllerOptions {
  workspacePath?: string | null;
  isActive?: boolean;
}

export function useGitDataController({ workspacePath, isActive }: GitDataControllerOptions) {
  const activeRepoPath = useRepositoryStore.use.activeRepoPath();
  const availableRepoPaths = useRepositoryStore.use.availableRepoPaths();
  const { syncWorkspaceRepositories, refreshWorkspaceRepositories } =
    useRepositoryStore.use.actions();
  const gitActions = useGitStore((state) => state.actions);
  const gitStatus = useGitStore((state) => state.gitStatus);
  const loadedCommitCount = useGitStore((state) => state.commits.length);
  const autoRefreshGitStatus = useSettingsStore((state) => state.settings.autoRefreshGitStatus);
  const workspaceFolders = useFileSystemStore((state) => state.workspaceFolders);
  const [failedRepoPath, setFailedRepoPath] = useState<string | null>(null);
  const requestIdRef = useRef(0);
  const refreshPromisesRef = useRef(new Map<string, Promise<void>>());
  const wasActiveRef = useRef(isActive);

  const loadInitialGitData = useCallback(async () => {
    const repoPath = activeRepoPath;
    if (!repoPath) {
      return;
    }

    const requestId = ++requestIdRef.current;
    gitActions.prepareRepositoryLoad(repoPath);
    gitActions.setIsLoadingGitData(true);

    try {
      const repoPaths = useRepositoryStore.getState().availableRepoPaths;
      const statusRepoPaths = repoPaths.length > 0 ? repoPaths : [repoPath];
      const [status, history, branches, stashes, operationStateResult] = await Promise.all([
        getWorkspaceGitStatus(statusRepoPaths, repoPath),
        getGitHistory(repoPath, 50),
        getBranches(repoPath),
        getStashes(repoPath),
        getOperationState(repoPath)
          .then((value) => ({ ok: true as const, value }))
          .catch((error) => {
            console.error("Failed to load Git operation state:", error);
            return { ok: false as const };
          }),
      ]);

      if (
        requestId !== requestIdRef.current ||
        useRepositoryStore.getState().activeRepoPath !== repoPath
      ) {
        return;
      }

      if (!status) throw new Error("Git status query returned no snapshot");
      // History can fail independently (for example before the first commit).
      // Keep its last snapshot while still allowing working-tree status to load.
      const previous = useGitStore.getState();
      setFailedRepoPath(history ? null : repoPath);
      gitActions.loadFreshGitData({
        gitStatus: status,
        commits: history?.commits ?? previous.commits,
        hasMoreCommits: history?.hasMore ?? previous.hasMoreCommits,
        branches,
        stashes,
        operationState: operationStateResult.ok ? operationStateResult.value : null,
        repoPath,
      });
    } catch (error) {
      if (requestId === requestIdRef.current) {
        setFailedRepoPath(repoPath);
        console.error("Failed to load initial git data:", error);
      }
    } finally {
      if (requestId === requestIdRef.current) {
        gitActions.setIsLoadingGitData(false);
      }
    }
  }, [activeRepoPath, availableRepoPaths, gitActions]);

  const refreshGitData = useCallback(
    async (scopes?: GitChangeScope[]) => {
      const repoPath = activeRepoPath;
      if (!repoPath) return;

      const refreshKey = `${repoPath}\0${scopes?.slice().sort().join(",") || "*"}`;
      const existingRequest = refreshPromisesRef.current.get(refreshKey);
      if (existingRequest) return existingRequest;

      const requestId = requestIdRef.current;
      const request = (async () => {
        try {
          const refreshAll = !scopes?.length;
          const shouldRefreshHistory = refreshAll || scopes.includes("history");
          const shouldRefreshRefs =
            refreshAll || scopes.includes("refs") || scopes.includes("repository");
          const shouldRefreshStashes =
            refreshAll || scopes.includes("stashes") || scopes.includes("repository");
          const repoPaths = useRepositoryStore.getState().availableRepoPaths;
          const statusRepoPaths = repoPaths.length > 0 ? repoPaths : [repoPath];
          const [status, branches, stashes, history, operationStateResult] = await Promise.all([
            getWorkspaceGitStatus(statusRepoPaths, repoPath),
            shouldRefreshRefs ? getBranches(repoPath) : Promise.resolve(undefined),
            shouldRefreshStashes ? getStashes(repoPath) : Promise.resolve(undefined),
            shouldRefreshHistory
              ? getGitHistory(repoPath, Math.max(loadedCommitCount, 50))
              : Promise.resolve(undefined),
            // Operation state rides along on every refresh: staging a file or
            // an external Git command can end a conflict at any moment.
            getOperationState(repoPath)
              .then((value) => ({ ok: true as const, value }))
              .catch((error) => {
                console.error("Failed to refresh Git operation state:", error);
                return { ok: false as const };
              }),
          ]);

          if (
            requestId !== requestIdRef.current ||
            useRepositoryStore.getState().activeRepoPath !== repoPath
          ) {
            return;
          }

          if (!status) throw new Error("Git status query returned no snapshot");
          setFailedRepoPath(shouldRefreshHistory && !history ? repoPath : null);
          gitActions.refreshGitData({
            gitStatus: status,
            branches,
            commits: history?.commits,
            hasMoreCommits: history?.hasMore,
            operationState: operationStateResult.ok ? operationStateResult.value : undefined,
            repoPath,
          });

          if (
            stashes &&
            requestId === requestIdRef.current &&
            useRepositoryStore.getState().activeRepoPath === repoPath
          ) {
            gitActions.setStashes(stashes);
          }
        } catch (error) {
          if (requestId === requestIdRef.current) {
            setFailedRepoPath(repoPath);
            console.error("Failed to refresh git data:", error);
          }
        }
      })().finally(() => {
        if (refreshPromisesRef.current.get(refreshKey) === request) {
          refreshPromisesRef.current.delete(refreshKey);
        }
      });

      refreshPromisesRef.current.set(refreshKey, request);
      return request;
    },
    [activeRepoPath, availableRepoPaths, gitActions, loadedCommitCount],
  );

  const refresh = useCallback(async () => {
    // An explicit retry must not reuse a cached negative repository discovery.
    if (failedRepoPath && failedRepoPath === activeRepoPath) clearRepositoryDiscoveryCache();
    gitActions.setIsRefreshing(true);
    try {
      await Promise.all([refreshGitData(), refreshWorkspaceRepositories()]);
    } finally {
      gitActions.setIsRefreshing(false);
    }
  }, [activeRepoPath, failedRepoPath, gitActions, refreshGitData, refreshWorkspaceRepositories]);

  useEffect(() => {
    const workspaceRootPaths = normalizeWorkspaceFolders(workspacePath ?? undefined, workspaceFolders).map(
      (folder) => folder.path,
    );
    void syncWorkspaceRepositories(workspaceRootPaths.length > 0 ? workspaceRootPaths : null);
  }, [syncWorkspaceRepositories, workspaceFolders, workspacePath]);

  useEffect(() => {
    requestIdRef.current += 1;
    setFailedRepoPath(null);
    refreshPromisesRef.current.clear();
    void loadInitialGitData();

    return () => {
      requestIdRef.current += 1;
    };
  }, [loadInitialGitData]);

  useEffect(() => {
    if (autoRefreshGitStatus && isActive && !wasActiveRef.current && gitStatus) {
      void refreshGitData();
    }
    wasActiveRef.current = isActive;
  }, [autoRefreshGitStatus, gitStatus, isActive, refreshGitData]);

  useEffect(() => {
    if (!activeRepoPath) return;

    let timeoutId: ReturnType<typeof setTimeout> | null = null;
    const unsubscribe = subscribeToGitChanges((change) => {
      const repoPaths = useRepositoryStore.getState().availableRepoPaths;
      const relevantRepoPaths = repoPaths.length > 0 ? repoPaths : [activeRepoPath];
      if (!relevantRepoPaths.some((repoPath) => isGitChangeRelevant(change, repoPath))) return;
      if (!autoRefreshGitStatus && isPassiveGitChange(change)) return;
      if (timeoutId) clearTimeout(timeoutId);
      timeoutId = setTimeout(() => void refreshGitData(change.scopes), 100);
    });

    return () => {
      unsubscribe();
      if (timeoutId) clearTimeout(timeoutId);
    };
  }, [activeRepoPath, autoRefreshGitStatus, refreshGitData]);

  return {
    activeRepoPath,
    hasLoadError: failedRepoPath !== null && failedRepoPath === activeRepoPath,
    refreshGitData,
    refresh,
  };
}
