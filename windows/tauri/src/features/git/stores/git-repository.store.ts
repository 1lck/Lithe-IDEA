import { createStore } from "zustand/vanilla";
import { createWorkspaceScopedStore } from "@/features/workspace/stores/create-workspace-scoped-store";
import { createSelectors } from "@/utils/zustand-selectors";
import { discoverWorkspaceRepositories, normalizeRepositoryPath } from "../api/git-repo-api";

interface RepositoryState {
  workspaceRootPath: string | null;
  workspaceDiscoveryKey: string | null;
  workspaceRepoPaths: string[];
  manualRepoPath: string | null;
  manualRepoPaths: string[];
  activeRepoPath: string | null;
  availableRepoPaths: string[];
  isDiscovering: boolean;
  hasDiscoveredWorkspace: boolean;
  discoveryRequestId: number;
  error: string | null;

  actions: {
    syncWorkspaceRepositories: (
      workspaceRootPath?: string | readonly string[] | null,
      options?: { force?: boolean },
    ) => Promise<void>;
    refreshWorkspaceRepositories: () => Promise<void>;
    selectRepository: (repoPath: string | null) => void;
    setManualRepository: (repoPath: string) => void;
    clearManualRepository: () => void;
    reset: () => void;
  };
}

const mergeRepositoryPaths = (workspaceRepos: string[], manualRepoPaths: string[]): string[] => {
  const result = [...workspaceRepos];
  const resultSet = new Set(result);

  for (const manualRepoPath of manualRepoPaths) {
    if (!resultSet.has(manualRepoPath)) {
      resultSet.add(manualRepoPath);
      result.push(manualRepoPath);
    }
  }
  return result;
};

// Stable path lists keep a successful rescan from restarting the data controller.
const reuseRepositoryPaths = (previous: string[], next: string[]): string[] =>
  previous.length === next.length && previous.every((path, index) => path === next[index])
    ? previous
    : next;

const getWorkspaceDefaultRepo = (workspaceRepos: string[]): string | null => {
  return workspaceRepos[0] ?? null;
};

const initialState = {
  workspaceRootPath: null,
  workspaceDiscoveryKey: null,
  workspaceRepoPaths: [],
  manualRepoPath: null,
  manualRepoPaths: [],
  activeRepoPath: null,
  availableRepoPaths: [],
  isDiscovering: false,
  hasDiscoveredWorkspace: false,
  discoveryRequestId: 0,
  error: null,
};

export const createGitRepositoryStore = () =>
  createStore<RepositoryState>()((set, get) => ({
    ...initialState,

    actions: {
      syncWorkspaceRepositories: async (workspaceRootPath, options) => {
        const force = options?.force ?? false;
        const normalizedRoots = (
          Array.isArray(workspaceRootPath) ? workspaceRootPath : [workspaceRootPath]
        )
          .filter((path): path is string => !!path)
          .map((path) => normalizeRepositoryPath(path));
        const normalizedRoot = normalizedRoots[0] ?? null;
        const workspaceDiscoveryKey = [...new Set(normalizedRoots)].join("\0");

        if (!normalizedRoot) {
          set((state) => {
            const availableRepoPaths = mergeRepositoryPaths([], state.manualRepoPaths);
            const activeRepoPath = state.activeRepoPath ?? state.manualRepoPath ?? null;
            return {
              workspaceRootPath: null,
              workspaceDiscoveryKey: null,
              workspaceRepoPaths: [],
              availableRepoPaths,
              activeRepoPath,
              isDiscovering: false,
              hasDiscoveredWorkspace: true,
              discoveryRequestId: state.discoveryRequestId + 1,
              error: null,
            };
          });
          return;
        }

        const current = get();
        if (
          !force &&
          current.workspaceDiscoveryKey === workspaceDiscoveryKey &&
          (current.hasDiscoveredWorkspace || current.isDiscovering)
        ) {
          return;
        }

        const requestId = current.discoveryRequestId + 1;
        set({
          workspaceRootPath: normalizedRoot,
          workspaceDiscoveryKey,
          isDiscovering: true,
          discoveryRequestId: requestId,
          error: null,
        });

        try {
          const discoveredRepos = await discoverWorkspaceRepositories(normalizedRoots, { force });

          set((state) => {
            if (
              state.discoveryRequestId !== requestId ||
              state.workspaceDiscoveryKey !== workspaceDiscoveryKey
            ) {
              return state;
            }

            const availableRepoPaths = mergeRepositoryPaths(discoveredRepos, state.manualRepoPaths);
            const availableRepoPathSet = new Set(availableRepoPaths);
            const previousActive = state.activeRepoPath;
            const hasPreviousActive = !!previousActive && availableRepoPathSet.has(previousActive);
            const nextActiveRepoPath = hasPreviousActive
              ? previousActive
              : state.manualRepoPath && availableRepoPathSet.has(state.manualRepoPath)
                ? state.manualRepoPath
                : getWorkspaceDefaultRepo(discoveredRepos);

            return {
              workspaceRootPath: normalizedRoot,
              workspaceDiscoveryKey,
              workspaceRepoPaths: reuseRepositoryPaths(state.workspaceRepoPaths, discoveredRepos),
              availableRepoPaths: reuseRepositoryPaths(state.availableRepoPaths, availableRepoPaths),
              activeRepoPath: nextActiveRepoPath,
              isDiscovering: false,
              hasDiscoveredWorkspace: true,
              error: null,
            };
          });
        } catch (error) {
          set((state) =>
            state.discoveryRequestId === requestId &&
            state.workspaceDiscoveryKey === workspaceDiscoveryKey
              ? {
                  isDiscovering: false,
                  hasDiscoveredWorkspace: true,
                  error: error instanceof Error ? error.message : String(error),
                }
              : state,
          );
        }
      },

      refreshWorkspaceRepositories: async () => {
        const { workspaceDiscoveryKey, actions } = get();
        await actions.syncWorkspaceRepositories(workspaceDiscoveryKey?.split("\0"), { force: true });
      },

      selectRepository: (repoPath) => {
        const normalizedRepoPath = repoPath ? normalizeRepositoryPath(repoPath) : null;
        set((state) => {
          const workspaceRepoPathSet = new Set(state.workspaceRepoPaths);
          const manualRepoPathSet = new Set(state.manualRepoPaths);
          const hasInWorkspace =
            !!normalizedRepoPath && workspaceRepoPathSet.has(normalizedRepoPath);
          const nextManualRepoPaths =
            normalizedRepoPath && !hasInWorkspace && !manualRepoPathSet.has(normalizedRepoPath)
              ? [...state.manualRepoPaths, normalizedRepoPath]
              : state.manualRepoPaths;
          const nextManualRepoPath = hasInWorkspace
            ? state.manualRepoPath
            : (normalizedRepoPath ?? state.manualRepoPath);
          const availableRepoPaths = mergeRepositoryPaths(
            state.workspaceRepoPaths,
            nextManualRepoPaths,
          );

          return {
            manualRepoPath: nextManualRepoPath,
            manualRepoPaths: nextManualRepoPaths,
            activeRepoPath: normalizedRepoPath,
            availableRepoPaths,
            error: null,
          };
        });
      },

      setManualRepository: (repoPath) => {
        const normalizedRepoPath = normalizeRepositoryPath(repoPath);
        set((state) => {
          const manualRepoPathSet = new Set(state.manualRepoPaths);
          const manualRepoPaths = manualRepoPathSet.has(normalizedRepoPath)
            ? state.manualRepoPaths
            : [...state.manualRepoPaths, normalizedRepoPath];
          const availableRepoPaths = mergeRepositoryPaths(
            state.workspaceRepoPaths,
            manualRepoPaths,
          );
          return {
            manualRepoPath: normalizedRepoPath,
            manualRepoPaths,
            activeRepoPath: normalizedRepoPath,
            availableRepoPaths,
            error: null,
          };
        });
      },

      clearManualRepository: () => {
        set((state) => {
          const availableRepoPaths = mergeRepositoryPaths(state.workspaceRepoPaths, []);
          const availableRepoPathSet = new Set(availableRepoPaths);
          const manualRepoPathSet = new Set(state.manualRepoPaths);
          const shouldResetActive =
            !!state.activeRepoPath && manualRepoPathSet.has(state.activeRepoPath);
          const nextActiveRepoPath = shouldResetActive
            ? getWorkspaceDefaultRepo(state.workspaceRepoPaths)
            : state.activeRepoPath && availableRepoPathSet.has(state.activeRepoPath)
              ? state.activeRepoPath
              : getWorkspaceDefaultRepo(state.workspaceRepoPaths);

          return {
            manualRepoPath: null,
            manualRepoPaths: [],
            activeRepoPath: nextActiveRepoPath,
            availableRepoPaths,
            error: null,
          };
        });
      },

      reset: () => set(initialState),
    },
  }));

export const useRepositoryStore = createSelectors(
  createWorkspaceScopedStore("git-repository", createGitRepositoryStore),
);
