import { createStore } from "zustand/vanilla";
import { cancelCoreOperation } from "@/core/lithe-core-client";
import { createWorkspaceScopedStore } from "@/features/workspace/stores/create-workspace-scoped-store";
import { getResolvedGitBlame } from "../api/git-blame-api";
import type { GitBlame, GitBlameLine } from "../types/git.types";
import { findGitBlameLine } from "../utils/git-blame-lines";

interface GitBlameState {
  blameData: Map<string, GitBlame>;
  requestIds: Map<string, number>;
  operationIds: Map<string, string>;
  nextRequestId: number;
  revision: number;
  isLoading: Map<string, boolean>;
  errors: Map<string, string>;
  fileToRepo: Map<string, string>;
  /**
   * Files whose annotation the user turned on from the gutter menu. IDEA scopes
   * annotate to the editor, not to a global preference, so visibility lives
   * with the file instead of the settings.
   */
  visibleFiles: Set<string>;

  actions: {
    /**
     * Loads blame once per file. `refresh` reloads a file whose blame is already
     * shown: the current lines stay until the new result replaces them, so a
     * repository change never blanks the annotation while Git runs.
     */
    loadBlameForFile: (
      repoPath: string,
      filePath: string,
      options?: { refresh?: boolean },
    ) => Promise<void>;
    clearAllBlame: () => void;
    getBlameForLine: (filePath: string, lineNumber: number) => GitBlameLine | null;
    getRepoPath: (filePath: string) => string | null;
    toggleBlameForFile: (filePath: string, visible?: boolean) => void;
  };
}

export const getGitBlameCacheKey = (repoPath: string, filePath: string) =>
  `${repoPath}\0${filePath}`;

export const createGitBlameStore = () =>
  createStore<GitBlameState>()((set, get) => ({
    blameData: new Map(),
    requestIds: new Map(),
    operationIds: new Map(),
    nextRequestId: 0,
    revision: 0,
    isLoading: new Map(),
    errors: new Map(),
    fileToRepo: new Map(),
    visibleFiles: new Set(),

    actions: {
      loadBlameForFile: async (repoPath: string, filePath: string, options) => {
        const state = get();
        const cacheKey = getGitBlameCacheKey(repoPath, filePath);
        if (!options?.refresh) {
          if (state.blameData.has(cacheKey) && !state.errors.has(cacheKey)) {
            return;
          }
          if (state.isLoading.get(cacheKey)) {
            return;
          }
        }

        const previousOperationId = state.operationIds.get(cacheKey);
        if (previousOperationId) {
          void cancelCoreOperation(previousOperationId);
        }

        const requestId = state.nextRequestId + 1;
        const operationId = crypto.randomUUID();
        const errors = new Map(state.errors);
        errors.delete(cacheKey);

        set({
          requestIds: new Map(state.requestIds).set(cacheKey, requestId),
          operationIds: new Map(state.operationIds).set(cacheKey, operationId),
          nextRequestId: requestId,
          isLoading: new Map(state.isLoading).set(cacheKey, true),
          errors,
        });

        const result = await getResolvedGitBlame(repoPath, filePath, operationId);
        if (get().requestIds.get(cacheKey) !== requestId) {
          return;
        }

        const operationIds = new Map(get().operationIds);
        operationIds.delete(cacheKey);

        if (result) {
          set({
            blameData: new Map(get().blameData).set(cacheKey, result.blame),
            fileToRepo: new Map(get().fileToRepo).set(filePath, result.repoPath),
            operationIds,
            isLoading: new Map(get().isLoading).set(cacheKey, false),
          });
        } else {
          const blameData = new Map(get().blameData);
          blameData.delete(cacheKey);
          set({
            blameData,
            operationIds,
            errors: new Map(get().errors).set(cacheKey, "Failed to load blame data"),
            isLoading: new Map(get().isLoading).set(cacheKey, false),
          });
        }
      },

      clearAllBlame: () => {
        for (const operationId of get().operationIds.values()) {
          void cancelCoreOperation(operationId);
        }
        set({
          blameData: new Map(),
          requestIds: new Map(),
          operationIds: new Map(),
          revision: get().revision + 1,
          isLoading: new Map(),
          errors: new Map(),
          fileToRepo: new Map(),
          visibleFiles: new Set(),
        });
      },

      toggleBlameForFile: (filePath: string, visible?: boolean) => {
        const state = get();
        const nextVisible = visible ?? !state.visibleFiles.has(filePath);
        if (nextVisible === state.visibleFiles.has(filePath)) return;

        const visibleFiles = new Set(state.visibleFiles);
        let blameData = state.blameData;
        if (nextVisible) {
          visibleFiles.add(filePath);
          // Blame cached while the annotation was off can be older than the
          // working tree, so turning annotate on reads it again.
          const suffix = `\0${filePath}`;
          const staleKeys = [...blameData.keys()].filter((key) => key.endsWith(suffix));
          if (staleKeys.length > 0) {
            blameData = new Map(blameData);
            for (const key of staleKeys) blameData.delete(key);
          }
        } else {
          visibleFiles.delete(filePath);
        }
        // The revision re-runs the load effect for the file that just became
        // visible; the shown lines stay until the new result replaces them.
        set({ blameData, visibleFiles, revision: state.revision + 1 });
      },

      getBlameForLine: (filePath: string, lineNumber: number) => {
        const suffix = `\0${filePath}`;
        const cacheKeys = Array.from(get().blameData.keys());
        let cacheKey: string | undefined;
        for (let index = cacheKeys.length - 1; index >= 0; index--) {
          if (cacheKeys[index].endsWith(suffix)) {
            cacheKey = cacheKeys[index];
            break;
          }
        }
        const blame = cacheKey ? get().blameData.get(cacheKey) : undefined;

        if (!blame) return null;

        return findGitBlameLine(blame.lines, lineNumber);
      },

      getRepoPath: (filePath: string) => {
        return get().fileToRepo.get(filePath) ?? null;
      },
    },
  }));

export const useGitBlameStore = createWorkspaceScopedStore("git-blame", createGitBlameStore);
