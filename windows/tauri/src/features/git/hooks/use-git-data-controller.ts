import { useCallback, useEffect, useRef, useState } from "react";
import { normalizeWorkspaceFolders } from "@/features/file-system/controllers/workspace-session";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { getBranches } from "../api/git-branches-api";
import { getOperationState } from "../api/git-integration-api";
import { clearRepositoryDiscoveryCache } from "../api/git-repo-api";
import { getStashes } from "../api/git-stash-api";
import { getRepositoryGitStatuses } from "../api/git-status-api";
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
  const autoRefreshGitStatus = useSettingsStore((state) => state.settings.autoRefreshGitStatus);
  const workspaceFolders = useFileSystemStore((state) => state.workspaceFolders);
  const [failedRepoPath, setFailedRepoPath] = useState<string | null>(null);
  const hasLoadError = activeRepoPath !== null && failedRepoPath === activeRepoPath;
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
      const repositoryStatuses = await getRepositoryGitStatuses(statusRepoPaths);

      if (
        requestId !== requestIdRef.current ||
        useRepositoryStore.getState().activeRepoPath !== repoPath
      ) {
        return;
      }

      if (!repositoryStatuses[repoPath]) throw new Error("Git status query returned no snapshot");
      setFailedRepoPath(null);
      gitActions.refreshGitData({
        repositoryStatuses,
        workingTreeVersion,
        repoPath,
      });

      // Commit history is not read here: the Commit panel no longer lists it, the
      // Git Log tool window pages its own history, and the compare-with-commit
      // picker loads commits when it opens.
      try {
        const [branches, stashes, operationStateResult] = await Promise.all([
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

        gitActions.refreshGitData({
          repositoryStatuses,
          workingTreeVersion,
          branches,
          operationState: operationStateResult.ok ? operationStateResult.value : null,
          repoPath,
        });
        gitActions.setStashes(stashes);
      } catch (error) {
        if (requestId === requestIdRef.current) {
          console.error("Failed to load optional initial Git data:", error);
        }
      }
    } catch (error) {
      if (requestId === requestIdRef.current) {
        setFailedRepoPath(repoPath);
        console.error("Failed to load initial Git status:", error);
      }
    } finally {
      if (requestId === requestIdRef.current) {
        gitActions.setIsLoadingGitData(false);
      }
    }
  }, [activeRepoPath, availableRepoPaths, gitActions, workspaceId]);

  const refreshGitData = useCallback(
    async (scopes?: GitChangeScope[], throwOnError = false, source: "user" | "background" = "user") => {
      if (!workspaceRuntimeRegistry.isWorkspaceReady(workspaceId)) return;
      const repoPath = activeRepoPath;
      if (!repoPath) return;

      const refreshKey = `${repoPath}\0${source}\0${scopes?.slice().sort().join(",") || "*"}`;
      const requestId = requestIdRef.current;
      return refreshQueueRef.current.run(refreshKey, async () => {
        // The queue starts on a later microtask and may execute a trailing
        // refresh after the workspace lifecycle has changed.
        if (!workspaceRuntimeRegistry.isWorkspaceReady(workspaceId)) return;
        // Allocate per actual read, including trailing reads, rather than per
        // caller joining a coalesced request.
        const workingTreeVersion = gitActions.beginWorkingTreeRefresh();
        try {
          const refreshAll = !scopes?.length;
          const shouldRefreshRefs =
            refreshAll || scopes.includes("refs") || scopes.includes("repository");
          const shouldRefreshStashes =
            refreshAll || scopes.includes("stashes") || scopes.includes("repository");
          const repoPaths = useRepositoryStore.getState().availableRepoPaths;
          const statusRepoPaths = repoPaths.length > 0 ? repoPaths : [repoPath];
          const [status, branches, stashes, operationStateResult] = await Promise.all([
            getRepositoryGitStatuses(statusRepoPaths, source),
            shouldRefreshRefs ? getBranches(repoPath, source) : Promise.resolve(undefined),
            shouldRefreshStashes ? getStashes(repoPath, source) : Promise.resolve(undefined),
            // Operation state rides along on every refresh: staging a file or
            // an external Git command can end a conflict at any moment.
            getOperationState(repoPath, source)
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

          if (!status[repoPath]) throw new Error("Git status query returned no snapshot");
          setFailedRepoPath(null);
          gitActions.refreshGitData({
            repositoryStatuses: status,
            workingTreeVersion,
            branches,
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
          throw error;
        }
      }).catch((error: unknown) => {
        if (throwOnError) throw error;
      });
    },
    [activeRepoPath, availableRepoPaths, gitActions, workspaceId],
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
    void loadInitialGitData();

    return () => {
      requestIdRef.current += 1;
    };
  }, [loadInitialGitData, workspaceReady]);

  useEffect(() => {
    if (autoRefreshGitStatus && isActive && !wasActiveRef.current && gitStatus) {
      void refreshGitData(undefined, false, "background");
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
        void refreshGitData(scopes, false, "background");
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
