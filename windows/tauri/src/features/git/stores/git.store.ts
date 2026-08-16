import { createStore } from "zustand/vanilla";
import { createWorkspaceScopedStore } from "@/features/workspace/stores/create-workspace-scoped-store";
import { getGitHistory } from "../api/git-commits-api";
import { getGitStatus } from "../api/git-status-api";
import type { GitCommit, GitStash, GitStatus } from "../types/git.types";

interface GitState {
  gitStatus: GitStatus | null;
  workspaceGitStatus: GitStatus | null;
  commits: GitCommit[];
  branches: string[];
  stashes: GitStash[];
  hasMoreCommits: boolean;
  isLoadingMoreCommits: boolean;
  isLoadingGitData: boolean;
  isRefreshing: boolean;
  currentRepoPath: string | null;
  currentWorkspaceRepoPath: string | null;
  workspaceGitStatusUpdatedAt: number;

  actions: {
    prepareRepositoryLoad: (repoPath: string) => void;
    loadFreshGitData: (data: {
      gitStatus: GitStatus | null;
      commits: GitCommit[];
      hasMoreCommits: boolean;
      branches: string[];
      stashes: GitStash[];
      repoPath: string;
    }) => void;
    refreshGitData: (data: {
      gitStatus: GitStatus | null;
      branches?: string[];
      commits?: GitCommit[];
      hasMoreCommits?: boolean;
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
    reset: () => void;
  };
}

const COMMITS_PER_PAGE = 50;
const MAX_COMMITS = 5_000;

export const createGitStore = () =>
  createStore<GitState>()((set, get) => ({
    gitStatus: null,
    workspaceGitStatus: null,
    commits: [],
    branches: [],
    stashes: [],
    hasMoreCommits: true,
    isLoadingMoreCommits: false,
    isLoadingGitData: false,
    isRefreshing: false,
    currentRepoPath: null,
    currentWorkspaceRepoPath: null,
    workspaceGitStatusUpdatedAt: 0,

    actions: {
      prepareRepositoryLoad: (repoPath) => {
        const state = get();
        if (state.currentRepoPath === repoPath) return;

        set({
          gitStatus: null,
          commits: [],
          branches: [],
          stashes: [],
          hasMoreCommits: true,
          isLoadingMoreCommits: false,
          currentRepoPath: repoPath,
        });
      },

      loadFreshGitData: ({
        gitStatus,
        commits,
        hasMoreCommits,
        branches,
        stashes,
        repoPath,
      }) => {
        if (get().currentRepoPath !== repoPath) {
          return;
        }

        set({
          gitStatus,
          commits,
          branches,
          stashes,
          hasMoreCommits,
          currentRepoPath: repoPath,
        });
      },

      refreshGitData: ({ gitStatus, branches, commits, hasMoreCommits, repoPath }) => {
        if (get().currentRepoPath !== repoPath) {
          return;
        }

        set({
          gitStatus,
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

      reset: () =>
        set({
          gitStatus: null,
          commits: [],
          branches: [],
          stashes: [],
          hasMoreCommits: true,
          isLoadingMoreCommits: false,
          isLoadingGitData: false,
          isRefreshing: false,
          currentRepoPath: null,
          currentWorkspaceRepoPath: null,
          workspaceGitStatus: null,
          workspaceGitStatusUpdatedAt: 0,
        }),
    },
  }));

export const useGitStore = createWorkspaceScopedStore("git", createGitStore);
