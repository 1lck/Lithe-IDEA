import { createStore } from "zustand/vanilla";
import { createWorkspaceScopedStore } from "@/features/workspace/stores/create-workspace-scoped-store";
import { getGitHistory } from "../api/git-commits-api";
import { getGitStatus } from "../api/git-status-api";
import type { GitCommit, GitOperationState, GitStash, GitStatus } from "../types/git.types";

interface GitSourceControlSession {
  commitSelectedPaths: string[];
  commitMessage: string;
  collapsedFolders: string[];
  collapsedSections: string[];
}

interface GitState {
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
      gitStatus: GitStatus | null;
      workingTreeVersion?: number;
      commits: GitCommit[];
      hasMoreCommits: boolean;
      branches: string[];
      stashes: GitStash[];
      operationState: GitOperationState | null;
      repoPath: string;
    }) => void;
    refreshGitData: (data: {
      gitStatus: GitStatus | null;
      workingTreeVersion?: number;
      branches?: string[];
      commits?: GitCommit[];
      hasMoreCommits?: boolean;
      operationState?: GitOperationState | null;
      repoPath: string;
    }) => void;
    refreshWorkspaceGitStatus: (repoPath: string) => Promise<void>;
    loadMoreCommits: (repoPath: string) => Promise<void>;
    setGitStatus: (status: GitStatus | null) => void;
    setWorkspaceGitStatus: (status: GitStatus | null, repoPath: string | null) => void;
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

const COMMITS_PER_PAGE = 50;
const MAX_COMMITS = 5_000;

export const createGitStore = () => {
  // Request bookkeeping stays outside observable state: starting a read must not
  // render the file list. Versions span all refresh scopes in this workspace.
  let nextWorkingTreeVersion = 0;
  let publishedWorkingTreeVersion = 0;
  const acceptWorkingTree = (version?: number) => {
    if (version === undefined) return true;
    if (version < publishedWorkingTreeVersion) return false;
    publishedWorkingTreeVersion = version;
    return true;
  };

  return createStore<GitState>()((set, get) => ({
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
        publishedWorkingTreeVersion = ++nextWorkingTreeVersion;

        set({
          gitStatus: null,
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
        gitStatus,
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

        const publishWorkingTree = acceptWorkingTree(workingTreeVersion);
        set({
          ...(publishWorkingTree ? { gitStatus, operationState } : {}),
          commits,
          branches,
          stashes,
          hasMoreCommits,
          currentRepoPath: repoPath,
        });
      },

      refreshGitData: ({ gitStatus, workingTreeVersion, branches, commits, hasMoreCommits, operationState, repoPath }) => {
        if (get().currentRepoPath !== repoPath) {
          return;
        }

        const publishWorkingTree = acceptWorkingTree(workingTreeVersion);
        // A stale scoped read has nothing left to publish; avoid even a no-op
        // store notification. Full reads may still contribute history and refs.
        if (!publishWorkingTree && !branches && !commits) return;
        set({
          ...(publishWorkingTree ? { gitStatus } : {}),
          ...(publishWorkingTree && operationState !== undefined ? { operationState } : {}),
          ...(branches ? { branches } : {}),
          ...(commits
            ? {
                commits,
                hasMoreCommits: hasMoreCommits ?? false,
              }
            : {}),
        });
      },

      refreshWorkspaceGitStatus: async (repoPath) => {
        const status = await getGitStatus(repoPath);

        if (get().currentWorkspaceRepoPath !== repoPath) {
          return;
        }

        set({
          workspaceGitStatus: status,
          workspaceGitStatusUpdatedAt: Date.now(),
        });
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

      setGitStatus: (status) => set({ gitStatus: status }),
      setWorkspaceGitStatus: (status, repoPath) =>
        set({
          workspaceGitStatus: status,
          currentWorkspaceRepoPath: repoPath,
          workspaceGitStatusUpdatedAt: Date.now(),
        }),
      setCommits: (commits) => set({ commits }),
      setBranches: (branches) => set({ branches }),
      setStashes: (stashes) => set({ stashes }),
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
        publishedWorkingTreeVersion = ++nextWorkingTreeVersion;
        set({
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
