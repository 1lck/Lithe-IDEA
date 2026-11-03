import { createStore } from "zustand/vanilla";
import { createWorkspaceScopedStore } from "@/features/workspace/stores/create-workspace-scoped-store";
import { createSelectors } from "@/utils/zustand-selectors";
import { discoverWorkspaceRepositories, invalidateWorkspaceRepositoryDiscovery, normalizeRepositoryPath, workspaceRepositoryDiscoveryPolicyKey } from "../api/git-repo-api";

interface RepositoryState {
  workspaceRootPath: string | null;
  workspaceDiscoveryKey: string | null;
  workspaceDiscoveryPolicyKey: string | null;
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
    invalidateWorkspaceRepositories: () => void;
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
  workspaceDiscoveryPolicyKey: null,
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
              workspaceDiscoveryPolicyKey: null,
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

        const requestId = get().discoveryRequestId + 1;
        let started = false;
        try {
          const policyKey = workspaceRepositoryDiscoveryPolicyKey(normalizedRoots);
          const current = get();
          if (!force && current.workspaceDiscoveryKey === workspaceDiscoveryKey &&
              current.workspaceDiscoveryPolicyKey === policyKey &&
              (current.hasDiscoveredWorkspace || current.isDiscovering)) return;
          set({ workspaceRootPath: normalizedRoot, workspaceDiscoveryKey,
            workspaceDiscoveryPolicyKey: policyKey, isDiscovering: true,
            discoveryRequestId: requestId, error: null });
          started = true;
          const discoveredRepos = await discoverWorkspaceRepositories(normalizedRoots, { force });
          if (get().discoveryRequestId !== requestId) return;
          if (workspaceRepositoryDiscoveryPolicyKey(normalizedRoots) !== policyKey) {
            set({ isDiscovering: false, hasDiscoveredWorkspace: false });
            await get().actions.syncWorkspaceRepositories(normalizedRoots, { force: true });
            return;
          }
          set((state) => {
            if (state.discoveryRequestId !== requestId || state.workspaceDiscoveryKey !== workspaceDiscoveryKey) return state;
            const availableRepoPaths = mergeRepositoryPaths(discoveredRepos, state.manualRepoPaths);
            const availableRepoPathSet = new Set(availableRepoPaths);
            const previousActive = state.activeRepoPath;
            const nextActiveRepoPath = previousActive && availableRepoPathSet.has(previousActive)
              ? previousActive
              : state.manualRepoPath && availableRepoPathSet.has(state.manualRepoPath)
                ? state.manualRepoPath : getWorkspaceDefaultRepo(discoveredRepos);
            return {
              workspaceRepoPaths: reuseRepositoryPaths(state.workspaceRepoPaths, discoveredRepos),
              availableRepoPaths: reuseRepositoryPaths(state.availableRepoPaths, availableRepoPaths),
              activeRepoPath: nextActiveRepoPath, isDiscovering: false,
              hasDiscoveredWorkspace: true, error: null,
            };
          });
        } catch (error) {
          // A failed preference read must also supersede an older scan. Keep
          // every successfully published binding until a new discovery succeeds.
          set((state) => (started
            ? state.discoveryRequestId !== requestId || state.workspaceDiscoveryKey !== workspaceDiscoveryKey
            : state.discoveryRequestId >= requestId) ? state : {
            workspaceRootPath: normalizedRoot, workspaceDiscoveryKey,
            discoveryRequestId: requestId, isDiscovering: false,
            hasDiscoveredWorkspace: false,
            error: error instanceof Error ? error.message : String(error),
          });
        }
      },

      refreshWorkspaceRepositories: async () => {
        const { workspaceDiscoveryKey, actions } = get();
        await actions.syncWorkspaceRepositories(workspaceDiscoveryKey?.split("\0"), { force: true });
      },

      invalidateWorkspaceRepositories: () => {
        invalidateWorkspaceRepositoryDiscovery(get().workspaceDiscoveryKey?.split("\0") ?? []);
        set((state) => ({
          discoveryRequestId: state.discoveryRequestId + 1,
          workspaceDiscoveryPolicyKey: null,
          hasDiscoveredWorkspace: false,
          isDiscovering: true,
        }));
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
          };
        });
      },

      reset: () => set(initialState),
    },
  }));

export const useRepositoryStore = createSelectors(
  createWorkspaceScopedStore("git-repository", createGitRepositoryStore),
);
