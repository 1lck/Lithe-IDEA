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
import { createGitRefreshQueue } from "../services/git-operation-coordinator";
import { useRepositoryStore } from "../stores/git-repository.store";
import { useGitStore } from "../stores/git.store";
import {
  useActiveWorkspaceId,
  useWorkspaceReady,
  useWorkspaceStoreScopeId,
} from "@/features/workspace/stores/create-workspace-scoped-store";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";

interface GitDataControllerOptions {
  workspacePath?: string | null;
  isActive?: boolean;
}

export function useGitDataController({ workspacePath, isActive }: GitDataControllerOptions) {
  const activeWorkspaceId = useActiveWorkspaceId();
  const scopedWorkspaceId = useWorkspaceStoreScopeId();
  const workspaceId = scopedWorkspaceId ?? activeWorkspaceId;
  const workspaceReady = useWorkspaceReady(workspaceId);
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
  const [failedHistoryRepoPath, setFailedHistoryRepoPath] = useState<string | null>(null);
  const hasLoadError = activeRepoPath !== null && (
    failedRepoPath === activeRepoPath || failedHistoryRepoPath === activeRepoPath
  );
  const requestIdRef = useRef(0);
  const refreshQueueRef = useRef(createGitRefreshQueue());
  const changeRefreshTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const pendingChangeScopesRef = useRef<GitChangeScope[] | undefined>(undefined);
  const wasActiveRef = useRef(isActive);

  const loadInitialGitData = useCallback(async () => {
    if (!workspaceRuntimeRegistry.isWorkspaceReady(workspaceId)) {
      return;
    }
    const repoPath = activeRepoPath;
    if (!repoPath) {
      return;
    }

    const requestId = ++requestIdRef.current;
    gitActions.prepareRepositoryLoad(repoPath);
    gitActions.setIsLoadingGitData(true);
    const workingTreeVersion = gitActions.beginWorkingTreeRefresh();

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
      setFailedRepoPath(null);
      setFailedHistoryRepoPath(history ? null : repoPath);
      gitActions.loadFreshGitData({
        gitStatus: status,
        workingTreeVersion,
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
        // No part of the initial snapshot was committed after a failed batch.
        setFailedHistoryRepoPath(repoPath);
        console.error("Failed to load initial git data:", error);
      }
    } finally {
      if (requestId === requestIdRef.current) {
        gitActions.setIsLoadingGitData(false);
      }
    }
  }, [activeRepoPath, availableRepoPaths, gitActions, workspaceId]);

  const refreshGitData = useCallback(
    async (scopes?: GitChangeScope[], throwOnError = false) => {
      if (!workspaceRuntimeRegistry.isWorkspaceReady(workspaceId)) return;
      const repoPath = activeRepoPath;
      if (!repoPath) return;

      const refreshKey = `${repoPath}\0${scopes?.slice().sort().join(",") || "*"}`;
      const requestId = requestIdRef.current;
      return refreshQueueRef.current.run(refreshKey, async () => {
        // Allocate per actual read, including trailing reads, rather than per
        // caller joining a coalesced request.
        const workingTreeVersion = gitActions.beginWorkingTreeRefresh();
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
          setFailedRepoPath(null);
          // A working-tree-only refresh cannot recover a failed history query.
          if (shouldRefreshHistory) setFailedHistoryRepoPath(history ? null : repoPath);
          gitActions.refreshGitData({
            gitStatus: status,
            workingTreeVersion,
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
            if (!scopes?.length || scopes.includes("history")) setFailedHistoryRepoPath(repoPath);
            console.error("Failed to refresh git data:", error);
          }
          throw error;
        }
      }).catch((error: unknown) => {
        if (throwOnError) throw error;
      });
    },
    [activeRepoPath, availableRepoPaths, gitActions, loadedCommitCount, workspaceId],
  );

  const refreshWorkingTree = useCallback(async () => {
    // The staging API also emits a change event. Consume its pending scoped refresh
    // so the button and the event share one read, while preserving broader events.
    if (
      changeRefreshTimerRef.current !== null &&
      pendingChangeScopesRef.current?.length &&
      pendingChangeScopesRef.current.every((scope) => scope === "working-tree")
    ) {
      clearTimeout(changeRefreshTimerRef.current);
      changeRefreshTimerRef.current = null;
      pendingChangeScopesRef.current = undefined;
    }
    await refreshGitData(["working-tree"], true);
  }, [refreshGitData]);

  const refresh = useCallback(async () => {
    // An explicit retry must not reuse a cached negative repository discovery.
    if (hasLoadError) clearRepositoryDiscoveryCache();
    gitActions.setIsRefreshing(true);
    try {
      await Promise.all([refreshGitData(), refreshWorkspaceRepositories()]);
    } finally {
      gitActions.setIsRefreshing(false);
    }
  }, [gitActions, hasLoadError, refreshGitData, refreshWorkspaceRepositories]);

  useEffect(() => {
    const workspaceRootPaths = normalizeWorkspaceFolders(workspacePath ?? undefined, workspaceFolders).map(
      (folder) => folder.path,
    );
    void syncWorkspaceRepositories(workspaceRootPaths.length > 0 ? workspaceRootPaths : null);
  }, [syncWorkspaceRepositories, workspaceFolders, workspacePath]);

  useEffect(() => {
    if (!workspaceReady) return;
    requestIdRef.current += 1;
    refreshQueueRef.current.clear();
    setFailedRepoPath(null);
    setFailedHistoryRepoPath(null);
    void loadInitialGitData();

    return () => {
      requestIdRef.current += 1;
    };
  }, [loadInitialGitData, workspaceReady]);

  useEffect(() => {
    if (autoRefreshGitStatus && isActive && !wasActiveRef.current && gitStatus) {
      void refreshGitData();
    }
    wasActiveRef.current = isActive;
  }, [autoRefreshGitStatus, gitStatus, isActive, refreshGitData]);

  useEffect(() => {
    if (!activeRepoPath) return;

    const unsubscribe = subscribeToGitChanges((change) => {
      const repoPaths = useRepositoryStore.getState().availableRepoPaths;
      const relevantRepoPaths = repoPaths.length > 0 ? repoPaths : [activeRepoPath];
      if (!relevantRepoPaths.some((repoPath) => isGitChangeRelevant(change, repoPath))) return;
      if (!autoRefreshGitStatus && isPassiveGitChange(change)) return;
      const hadPendingRefresh = changeRefreshTimerRef.current !== null;
      if (changeRefreshTimerRef.current !== null) clearTimeout(changeRefreshTimerRef.current);
      const pendingScopes = pendingChangeScopesRef.current;
      if (!hadPendingRefresh) {
        pendingChangeScopesRef.current = change.scopes;
      } else if (!pendingScopes?.length || !change.scopes?.length) {
        pendingChangeScopesRef.current = undefined;
      } else {
        pendingChangeScopesRef.current = [...new Set([...pendingScopes, ...change.scopes])];
      }
      changeRefreshTimerRef.current = setTimeout(() => {
        const scopes = pendingChangeScopesRef.current;
        changeRefreshTimerRef.current = null;
        pendingChangeScopesRef.current = undefined;
        void refreshGitData(scopes);
      }, 100);
    });

    return () => {
      unsubscribe();
      if (changeRefreshTimerRef.current !== null) clearTimeout(changeRefreshTimerRef.current);
      changeRefreshTimerRef.current = null;
      pendingChangeScopesRef.current = undefined;
    };
  }, [activeRepoPath, autoRefreshGitStatus, refreshGitData]);

  return {
    activeRepoPath,
    hasLoadError,
    refreshGitData,
    refreshWorkingTree,
    refresh,
  };
}
