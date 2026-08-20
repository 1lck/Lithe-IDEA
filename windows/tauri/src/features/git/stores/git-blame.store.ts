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

  actions: {
    loadBlameForFile: (repoPath: string, filePath: string) => Promise<void>;
    clearBlameForFile: (filePath: string) => void;
    clearAllBlame: () => void;
    getBlameForLine: (filePath: string, lineNumber: number) => GitBlameLine | null;
    getRepoPath: (filePath: string) => string | null;
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

    actions: {
      loadBlameForFile: async (repoPath: string, filePath: string) => {
        const state = get();
        const cacheKey = getGitBlameCacheKey(repoPath, filePath);
        if (state.blameData.has(cacheKey) && !state.errors.has(cacheKey)) {
          return;
        }
        if (state.isLoading.get(cacheKey)) {
          return;
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

      clearBlameForFile: (filePath: string) => {
        const state = get();
        const blameData = new Map(state.blameData);
        const requestIds = new Map(state.requestIds);
        const operationIds = new Map(state.operationIds);
        const isLoading = new Map(state.isLoading);
        const errors = new Map(state.errors);
        const fileToRepo = new Map(state.fileToRepo);

        const suffix = `\0${filePath}`;
        for (const key of new Set([
          ...blameData.keys(),
          ...requestIds.keys(),
          ...operationIds.keys(),
          ...isLoading.keys(),
          ...errors.keys(),
        ])) {
          if (!key.endsWith(suffix)) continue;
          const operationId = operationIds.get(key);
          if (operationId) {
            void cancelCoreOperation(operationId);
          }
          blameData.delete(key);
          requestIds.delete(key);
          operationIds.delete(key);
          isLoading.delete(key);
          errors.delete(key);
        }
        fileToRepo.delete(filePath);

        set({
          blameData,
          requestIds,
          operationIds,
          revision: state.revision + 1,
          isLoading,
          errors,
          fileToRepo,
        });
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
        });
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
