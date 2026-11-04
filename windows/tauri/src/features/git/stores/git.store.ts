import equal from "fast-deep-equal";
import { createStore } from "zustand/vanilla";
import { createWorkspaceScopedStore } from "@/features/workspace/stores/create-workspace-scoped-store";
import { getGitHistory } from "../api/git-commits-api";
import { getWorkspaceStatusRefresh } from "../api/git-status-api";
import {
  projectWorkspaceGitStatus,
  type GitRepositoryStatuses,
} from "../utils/git-workspace-status";
import type { GitCommit, GitOperationState, GitStash, GitStatus } from "../types/git.types";

interface GitSourceControlSession {
  commitSelectedPaths: string[];
  commitMessage: string;
  collapsedFolders: string[];
  collapsedSections: string[];
}

interface GitState {
  repositoryStatuses: GitRepositoryStatuses;
  statusRepoPaths: readonly string[];
  failedStatusRoots: readonly string[];
  // Read-only projections, published atomically from repositoryStatuses.
  gitStatus: GitStatus | null;
  workspaceGitStatus: GitStatus | null;
  commits: GitCommit[];
  branches: string[];
  stashes: GitStash[];
  operationState: GitOperationState | null;
  hasMoreCommits: boolean;
  isLoadingMoreCommits: boolean;
  isLoadingGitData: boolean;
  isRefreshing: boolean;
  currentRepoPath: string | null;
  currentWorkspaceRepoPath: string | null;
  workspaceGitStatusUpdatedAt: number;
  sourceControlSessions: Record<string, GitSourceControlSession>;

  actions: {
    beginWorkingTreeRefresh: () => number;
    prepareRepositoryLoad: (repoPath: string) => void;
    loadFreshGitData: (data: {
      repositoryStatuses: GitRepositoryStatuses;
      workingTreeVersion?: number;
      commits: GitCommit[];
      hasMoreCommits: boolean;
      branches: string[];
      stashes: GitStash[];
      operationState: GitOperationState | null;
      repoPath: string;
    }) => void;
    refreshGitData: (data: {
      repositoryStatuses: GitRepositoryStatuses;
      failedStatusRoots?: readonly string[];
      workingTreeVersion?: number;
      branches?: string[];
      commits?: GitCommit[];
      hasMoreCommits?: boolean;
      operationState?: GitOperationState | null;
      repoPath: string;
    }) => void;
    publishRepositoryStatuses: (
      statuses: GitRepositoryStatuses,
      version?: number,
      repoPaths?: readonly string[],
      failedStatusRoots?: readonly string[],
    ) => void;
    refreshRepositoryStatuses: (
      repoPaths: readonly string[],
      requiredRepoPaths?: readonly string[],
    ) => Promise<void>;
    loadMoreCommits: (repoPath: string) => Promise<void>;
    setWorkspaceRepository: (repoPath: string | null) => void;
    setCommits: (commits: GitCommit[]) => void;
    setBranches: (branches: string[]) => void;
    setStashes: (stashes: GitStash[]) => void;
    setIsLoadingGitData: (loading: boolean) => void;
    setIsRefreshing: (refreshing: boolean) => void;
    updateSourceControlSession: (
      repoPath: string,
      update: Partial<GitSourceControlSession>,
    ) => void;
    reset: () => void;
  };
}

// Native queries deserialize fresh objects even when nothing changed. Reuse
// equal snapshots so status trees and history selectors avoid rebuilding.
const reuseSnapshot = <T>(previous: T, next: T): T => (equal(previous, next) ? previous : next);

const COMMITS_PER_PAGE = 50;
const MAX_COMMITS = 5_000;

export const createGitStore = () => {
  // Request bookkeeping stays outside observable state: starting a read must not
  // render the file list. Versions span all refresh scopes in this workspace.
  let nextWorkingTreeVersion = 0;
  let publishedWorkingTreeVersion = 0;
  // Operation state is only read by full refreshes. Its watermark advances only when
  // an operation state is published, so a newer status-only publication (which moves
  // the working-tree watermark) cannot reject an older full read's operation state.
  let publishedOperationVersion = 0;
  const acceptWorkingTree = (version: number) => {
    if (version < publishedWorkingTreeVersion) return false;
    publishedWorkingTreeVersion = version;
    return true;
  };
  const acceptOperationState = (version: number) => {
    if (version < publishedOperationVersion) return false;
    publishedOperationVersion = version;
    return true;
  };
  // A new repository or workspace session invalidates every read issued before it.
  const invalidatePendingReads = () => {
    publishedWorkingTreeVersion = publishedOperationVersion = ++nextWorkingTreeVersion;
  };

  // Note: .agents/notes/implemented/architecture/2026-10-08-windows-git-status-ownership.md
  const statusProjection = (
    state: GitState,
    incoming: GitRepositoryStatuses,
    repoPaths = state.statusRepoPaths,
    failedRoots = state.failedStatusRoots,
  ) => {
    const reused = Object.fromEntries(
      Object.entries(incoming).map(([path, status]) => [
        path,
        reuseSnapshot(state.repositoryStatuses[path] ?? null, status),
      ]),
    );
    const allowed = new Set([...repoPaths, ...(state.currentWorkspaceRepoPath ? [state.currentWorkspaceRepoPath] : [])]);
    const retained = Object.fromEntries(Object.entries(state.repositoryStatuses).filter(([root]) => allowed.has(root)));
    const repositoryStatuses = reuseSnapshot(state.repositoryStatuses, {
      ...retained,
      ...reused,
    });
    const statusRepoPaths = reuseSnapshot(state.statusRepoPaths, repoPaths);
    const gitStatus = reuseSnapshot(
      state.gitStatus,
      projectWorkspaceGitStatus(repositoryStatuses, statusRepoPaths, state.currentRepoPath),
    );
    const workspaceGitStatus = state.currentWorkspaceRepoPath
      ? (repositoryStatuses[state.currentWorkspaceRepoPath] ?? null)
      : null;
    return {
      repositoryStatuses,
      statusRepoPaths,
      failedStatusRoots: reuseSnapshot(state.failedStatusRoots, failedRoots),
      gitStatus,
      workspaceGitStatus,
      workspaceGitStatusUpdatedAt:
        workspaceGitStatus === state.workspaceGitStatus
          ? state.workspaceGitStatusUpdatedAt
          : Date.now(),
    };
  };

  return createStore<GitState>()((set, get) => ({
    repositoryStatuses: {},
    statusRepoPaths: [],
    failedStatusRoots: [],
    gitStatus: null,
    workspaceGitStatus: null,
    commits: [],
    branches: [],
    stashes: [],
    operationState: null,
    hasMoreCommits: true,
    isLoadingMoreCommits: false,
    isLoadingGitData: false,
    isRefreshing: false,
    currentRepoPath: null,
    currentWorkspaceRepoPath: null,
    workspaceGitStatusUpdatedAt: 0,
    sourceControlSessions: {},

    actions: {
      beginWorkingTreeRefresh: () => ++nextWorkingTreeVersion,

      prepareRepositoryLoad: (repoPath) => {
        const state = get();
        if (state.currentRepoPath === repoPath) return;
        invalidatePendingReads();

        set({
          gitStatus: projectWorkspaceGitStatus(
            state.repositoryStatuses,
            state.statusRepoPaths,
            repoPath,
          ),
          commits: [],
          branches: [],
          stashes: [],
          operationState: null,
          hasMoreCommits: true,
          isLoadingMoreCommits: false,
          currentRepoPath: repoPath,
        });
      },

      loadFreshGitData: ({
        repositoryStatuses,
        workingTreeVersion,
        commits,
        hasMoreCommits,
        branches,
        stashes,
        operationState,
        repoPath,
      }) => {
        if (get().currentRepoPath !== repoPath) {
          return;
        }

        const version = workingTreeVersion ?? ++nextWorkingTreeVersion;
        const publishWorkingTree = acceptWorkingTree(version);
        const publishOperationState = acceptOperationState(version);
        set((state) => ({
          ...(publishWorkingTree
            ? statusProjection(state, repositoryStatuses, Object.keys(repositoryStatuses))
            : {}),
          ...(publishOperationState ? { operationState } : {}),
          commits,
          branches,
          stashes,
          hasMoreCommits,
          currentRepoPath: repoPath,
        }));
      },

      refreshGitData: ({
        repositoryStatuses,
        failedStatusRoots,
        workingTreeVersion,
        branches,
        commits,
        hasMoreCommits,
        operationState,
        repoPath,
      }) => {
        set((state) => {
          if (state.currentRepoPath !== repoPath) return state;
          const version = workingTreeVersion ?? ++nextWorkingTreeVersion;
          const publishWorkingTree = acceptWorkingTree(version);
          const publishOperationState =
            operationState !== undefined && acceptOperationState(version);
          const next = {
            ...(publishWorkingTree
              ? statusProjection(state, repositoryStatuses, Object.keys(repositoryStatuses), failedStatusRoots)
              : {}),
            operationState: publishOperationState
              ? reuseSnapshot(state.operationState, operationState)
              : state.operationState,
            branches:
              branches === undefined ? state.branches : reuseSnapshot(state.branches, branches),
            commits: commits === undefined ? state.commits : reuseSnapshot(state.commits, commits),
            hasMoreCommits:
              commits === undefined ? state.hasMoreCommits : (hasMoreCommits ?? false),
          };
          if (
            (!publishWorkingTree ||
              (next.repositoryStatuses === state.repositoryStatuses &&
                next.statusRepoPaths === state.statusRepoPaths &&
                next.failedStatusRoots === state.failedStatusRoots)) &&
            next.operationState === state.operationState &&
            next.branches === state.branches &&
            next.commits === state.commits &&
            next.hasMoreCommits === state.hasMoreCommits
          )
            return state;
          return next;
        });
      },

      publishRepositoryStatuses: (statuses, version, repoPaths, failedRoots) => {
        if (!acceptWorkingTree(version ?? ++nextWorkingTreeVersion)) return;
        set((state) => {
          const next = statusProjection(
            state,
            statuses,
            repoPaths ??
              (state.statusRepoPaths.length ? state.statusRepoPaths : Object.keys(statuses)),
            failedRoots,
          );
          return next.repositoryStatuses === state.repositoryStatuses &&
            next.statusRepoPaths === state.statusRepoPaths &&
            next.failedStatusRoots === state.failedStatusRoots
            ? state
            : next;
        });
      },

      refreshRepositoryStatuses: async (repoPaths, requiredRepoPaths = repoPaths) => {
        const version = ++nextWorkingTreeVersion;
        const result = await getWorkspaceStatusRefresh(repoPaths, "background", requiredRepoPaths, get().repositoryStatuses);
        get().actions.publishRepositoryStatuses(result.statuses, version, requiredRepoPaths, result.failedRoots);
      },

      loadMoreCommits: async (repoPath) => {
        const { commits, currentRepoPath, hasMoreCommits, isLoadingMoreCommits } = get();

        if (currentRepoPath !== repoPath || !hasMoreCommits || isLoadingMoreCommits) return;

        if (commits.length >= MAX_COMMITS) {
          set({ hasMoreCommits: false });
          return;
        }

        set({ isLoadingMoreCommits: true });

        try {
          const requestedLimit = Math.min(commits.length + COMMITS_PER_PAGE, MAX_COMMITS);
          const history = await getGitHistory(repoPath, requestedLimit);
          if (!history || get().currentRepoPath !== repoPath) {
            return;
          }

          set({
            commits: history.commits,
            hasMoreCommits: history.hasMore && requestedLimit < MAX_COMMITS,
          });
        } finally {
          if (get().currentRepoPath === repoPath) {
            set({ isLoadingMoreCommits: false });
          }
        }
      },

      setWorkspaceRepository: (repoPath) => {
        if (get().currentWorkspaceRepoPath === repoPath) return;
        publishedWorkingTreeVersion = ++nextWorkingTreeVersion;
        set({
          repositoryStatuses: {},
          statusRepoPaths: [],
          failedStatusRoots: [],
          gitStatus: null,
          workspaceGitStatus: null,
          currentWorkspaceRepoPath: repoPath,
          workspaceGitStatusUpdatedAt: 0,
        });
      },
      setCommits: (commits) => set({ commits }),
      setBranches: (branches) => set({ branches }),
      setStashes: (stashes) =>
        set((state) => (equal(state.stashes, stashes) ? state : { stashes })),
      setIsLoadingGitData: (loading) => set({ isLoadingGitData: loading }),
      setIsRefreshing: (refreshing) => set({ isRefreshing: refreshing }),
      updateSourceControlSession: (repoPath, update) =>
        set((state) => {
          const current = state.sourceControlSessions[repoPath] ?? {
            commitSelectedPaths: [],
            commitMessage: "",
            collapsedFolders: [],
            collapsedSections: [],
          };
          return {
            sourceControlSessions: {
              ...state.sourceControlSessions,
              [repoPath]: { ...current, ...update },
            },
          };
        }),

      reset: () => {
        invalidatePendingReads();
        set({
          repositoryStatuses: {},
          statusRepoPaths: [],
          failedStatusRoots: [],
          gitStatus: null,
          commits: [],
          branches: [],
          stashes: [],
          operationState: null,
          hasMoreCommits: true,
          isLoadingMoreCommits: false,
          isLoadingGitData: false,
          isRefreshing: false,
          currentRepoPath: null,
          currentWorkspaceRepoPath: null,
          workspaceGitStatus: null,
          workspaceGitStatusUpdatedAt: 0,
        });
      },
    },
  }));
};

export const useGitStore = createWorkspaceScopedStore("git", createGitStore);
