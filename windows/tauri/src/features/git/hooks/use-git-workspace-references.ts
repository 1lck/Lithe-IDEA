import { useCallback, useEffect, useRef, useState } from "react";
import { cancelGitHistoryOperation, getGitReferencesAtRoot } from "../api/git-commits-api";
import { normalizeRepositoryPath } from "../api/git-repo-api";
import { subscribeToGitChanges } from "../events/git-events";
import type { GitReference } from "../types/git.types";
import { shouldRefreshGitLogForChange } from "../utils/git-log-refresh";

interface GitWorkspaceReferencesState {
  referencesByRepository: Map<string, GitReference[]>;
  errorsByRepository: Map<string, string>;
  isLoading: boolean;
  error: string | null;
}

const EMPTY_STATE: GitWorkspaceReferencesState = {
  referencesByRepository: new Map(),
  errorsByRepository: new Map(),
  isLoading: false,
  error: null,
};

const REFRESH_DEBOUNCE_MS = 100;
let nextControllerId = 0;

/** Injected timer source so debounced refreshes can be driven deterministically. */
export interface GitWorkspaceReferencesScheduler {
  setTimer(callback: () => void, delayMilliseconds: number): ReturnType<typeof setTimeout>;
  clearTimer(timer: ReturnType<typeof setTimeout>): void;
}

const defaultScheduler: GitWorkspaceReferencesScheduler = {
  setTimer: (callback, delayMilliseconds) => setTimeout(callback, delayMilliseconds),
  clearTimer: (timer) => clearTimeout(timer),
};

/**
 * Loads references for every repository in a workspace so the Git Log reference
 * tree can group branches by repository, while keeping each repository's read
 * independently cancellable.
 */
export function useGitWorkspaceReferences(
  repositoryPaths: string[],
  scheduler: GitWorkspaceReferencesScheduler = defaultScheduler,
) {
  const [state, setState] = useState<GitWorkspaceReferencesState>(EMPTY_STATE);
  const controllerIdRef = useRef<number | null>(null);
  const generationsRef = useRef(new Map<string, number>());
  const activeOperationIdsRef = useRef(new Set<string>());
  const repositoryPathsRef = useRef(repositoryPaths);
  const scheduledRefreshTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const pendingRefreshPathsRef = useRef(new Set<string>());

  repositoryPathsRef.current = repositoryPaths;
  if (controllerIdRef.current === null) controllerIdRef.current = ++nextControllerId;

  const isTrackedRepository = useCallback((repositoryKey: string) => {
    return repositoryPathsRef.current.some(
      (repositoryPath) => normalizeRepositoryPath(repositoryPath) === repositoryKey,
    );
  }, []);

  const loadRepository = useCallback(
    async (repositoryPath: string) => {
      const repositoryKey = normalizeRepositoryPath(repositoryPath);
      const generation = (generationsRef.current.get(repositoryKey) ?? 0) + 1;
      generationsRef.current.set(repositoryKey, generation);
      const operationId = `git-workspace-references-${controllerIdRef.current}-${repositoryKey}-${generation}`;
      activeOperationIdsRef.current.add(operationId);

      try {
        const snapshot = await getGitReferencesAtRoot(repositoryPath, operationId);
        if (generationsRef.current.get(repositoryKey) !== generation) return;
        if (!isTrackedRepository(repositoryKey)) return;
        const references = (snapshot?.references ?? []).map((reference) => ({
          ...reference,
          repositoryPath: repositoryKey,
        }));
        setState((current) => {
          const referencesByRepository = new Map(current.referencesByRepository);
          referencesByRepository.set(repositoryKey, references);
          const errorsByRepository = new Map(current.errorsByRepository);
          errorsByRepository.delete(repositoryKey);
          return { ...current, referencesByRepository, errorsByRepository, error: null };
        });
      } catch (error) {
        if (generationsRef.current.get(repositoryKey) !== generation) return;
        if (!isTrackedRepository(repositoryKey)) return;
        const message = error instanceof Error ? error.message : String(error);
        setState((current) => {
          // Drop any stale references so a failed load cannot surface as "0 references".
          const referencesByRepository = new Map(current.referencesByRepository);
          referencesByRepository.delete(repositoryKey);
          const errorsByRepository = new Map(current.errorsByRepository);
          errorsByRepository.set(repositoryKey, message);
          return { ...current, referencesByRepository, errorsByRepository, error: message };
        });
      } finally {
        activeOperationIdsRef.current.delete(operationId);
      }
    },
    [isTrackedRepository],
  );

  const cancelActiveOperations = useCallback(() => {
    for (const operationId of activeOperationIdsRef.current) {
      void cancelGitHistoryOperation(operationId);
    }
    activeOperationIdsRef.current.clear();
  }, []);

  const cancelScheduledRefresh = useCallback(() => {
    const timeoutId = scheduledRefreshTimeoutRef.current;
    scheduledRefreshTimeoutRef.current = null;
    pendingRefreshPathsRef.current.clear();
    if (timeoutId !== null) scheduler.clearTimer(timeoutId);
  }, [scheduler]);

  const scheduleRefresh = useCallback(
    (repositoryPath: string) => {
      pendingRefreshPathsRef.current.add(repositoryPath);
      if (scheduledRefreshTimeoutRef.current !== null) return;

      scheduledRefreshTimeoutRef.current = scheduler.setTimer(() => {
        scheduledRefreshTimeoutRef.current = null;
        const targets = [...pendingRefreshPathsRef.current];
        pendingRefreshPathsRef.current.clear();
        void (async () => {
          for (const target of targets) await loadRepository(target);
        })();
      }, REFRESH_DEBOUNCE_MS);
    },
    [loadRepository, scheduler],
  );

  const repositoryPathsKey = [...new Set(repositoryPaths.map(normalizeRepositoryPath))].join("\0");

  const retryRepository = useCallback(
    (repositoryPath: string) => {
      if (!isTrackedRepository(normalizeRepositoryPath(repositoryPath))) return;
      void loadRepository(repositoryPath);
    },
    [isTrackedRepository, loadRepository],
  );

  useEffect(() => {
    cancelScheduledRefresh();
    cancelActiveOperations();
    const keys = repositoryPathsKey ? repositoryPathsKey.split("\0") : [];
    for (const key of generationsRef.current.keys()) {
      if (!keys.includes(key)) {
        generationsRef.current.set(key, (generationsRef.current.get(key) ?? 0) + 1);
      }
    }
    setState((current) => {
      const referencesByRepository = new Map<string, GitReference[]>();
      for (const key of keys) {
        const references = current.referencesByRepository.get(key);
        if (references) referencesByRepository.set(key, references);
      }
      const errorsByRepository = new Map<string, string>();
      for (const key of keys) {
        const error = current.errorsByRepository.get(key);
        if (error) errorsByRepository.set(key, error);
      }
      if (
        referencesByRepository.size === current.referencesByRepository.size &&
        errorsByRepository.size === current.errorsByRepository.size
      ) {
        return current;
      }
      return { ...current, referencesByRepository, errorsByRepository };
    });

    if (keys.length === 0) return;
    let cancelled = false;
    setState((current) => ({ ...current, isLoading: true, error: null }));
    // Load repositories one at a time so a large workspace does not fan out one
    // native reference read per repository at the same moment.
    void (async () => {
      for (const key of keys) {
        if (cancelled) return;
        await loadRepository(key);
      }
    })().finally(() => {
      if (!cancelled) setState((current) => ({ ...current, isLoading: false }));
    });

    return () => {
      cancelled = true;
    };
  }, [cancelActiveOperations, cancelScheduledRefresh, loadRepository, repositoryPathsKey]);

  useEffect(() => {
    const unsubscribe = subscribeToGitChanges((change) => {
      for (const repositoryPath of repositoryPathsRef.current) {
        if (shouldRefreshGitLogForChange(change, repositoryPath)) {
          scheduleRefresh(repositoryPath);
        }
      }
    });

    return () => {
      unsubscribe();
      cancelScheduledRefresh();
    };
  }, [cancelScheduledRefresh, scheduleRefresh]);

  useEffect(
    () => () => {
      cancelScheduledRefresh();
      cancelActiveOperations();
      generationsRef.current.clear();
    },
    [cancelActiveOperations, cancelScheduledRefresh],
  );

  return {
    referencesByRepository: state.referencesByRepository,
    errorsByRepository: state.errorsByRepository,
    isLoading: state.isLoading,
    error: state.error,
    retryRepository,
  };
}
