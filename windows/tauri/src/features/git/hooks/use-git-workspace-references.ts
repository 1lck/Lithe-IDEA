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
 * Loads references per repository for the Git Log reference tree. Only the
 * active repository is read eagerly; the others stay lazy and are fetched on
 * demand through `ensureRepository`, then cached until a Git change invalidates
 * them. Reads stay serialized because resolving sibling worktrees of the same
 * common dir would otherwise race for the repository write lease.
 */
export function useGitWorkspaceReferences(
  repositoryPaths: string[],
  activeRepositoryPath: string | null | undefined,
  scheduler: GitWorkspaceReferencesScheduler = defaultScheduler,
) {
  const [state, setState] = useState<GitWorkspaceReferencesState>(EMPTY_STATE);
  const controllerIdRef = useRef<number | null>(null);
  const generationsRef = useRef(new Map<string, number>());
  // Operations keyed by repository so a removed repository can cancel only its
  // own in-flight read without disturbing another repository's load.
  const activeOperationsRef = useRef(new Map<string, Set<string>>());
  const requestedRepositoryKeysRef = useRef(new Set<string>());
  const loadChainRef = useRef<Promise<void>>(Promise.resolve());
  const pendingLoadCountRef = useRef(0);
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

  const finishLoad = useCallback(() => {
    pendingLoadCountRef.current = Math.max(0, pendingLoadCountRef.current - 1);
    if (pendingLoadCountRef.current === 0) {
      setState((current) => (current.isLoading ? { ...current, isLoading: false } : current));
    }
  }, []);

  const loadRepository = useCallback(
    async (repositoryPath: string) => {
      const repositoryKey = normalizeRepositoryPath(repositoryPath);
      const generation = (generationsRef.current.get(repositoryKey) ?? 0) + 1;
      generationsRef.current.set(repositoryKey, generation);
      const operationId = `git-workspace-references-${controllerIdRef.current}-${repositoryKey}-${generation}`;
      const operations = activeOperationsRef.current.get(repositoryKey) ?? new Set<string>();
      operations.add(operationId);
      activeOperationsRef.current.set(repositoryKey, operations);

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
        operations.delete(operationId);
        if (operations.size === 0) activeOperationsRef.current.delete(repositoryKey);
        finishLoad();
      }
    },
    [finishLoad, isTrackedRepository],
  );

  const cancelRepositoryOperations = useCallback((repositoryKey: string) => {
    const operations = activeOperationsRef.current.get(repositoryKey);
    if (!operations) return;
    for (const operationId of operations) void cancelGitHistoryOperation(operationId);
    activeOperationsRef.current.delete(repositoryKey);
  }, []);

  const cancelAllOperations = useCallback(() => {
    for (const repositoryKey of [...activeOperationsRef.current.keys()]) {
      cancelRepositoryOperations(repositoryKey);
    }
  }, [cancelRepositoryOperations]);

  const requestRepository = useCallback(
    (repositoryPath: string, force = false): Promise<void> => {
      const repositoryKey = normalizeRepositoryPath(repositoryPath);
      if (!isTrackedRepository(repositoryKey)) return Promise.resolve();
      if (!force && requestedRepositoryKeysRef.current.has(repositoryKey)) {
        return Promise.resolve();
      }
      requestedRepositoryKeysRef.current.add(repositoryKey);
      pendingLoadCountRef.current += 1;
      setState((current) => (current.isLoading ? current : { ...current, isLoading: true }));
      const task = loadChainRef.current.then(() => loadRepository(repositoryPath));
      loadChainRef.current = task.then(
        () => undefined,
        () => undefined,
      );
      return task;
    },
    [isTrackedRepository, loadRepository],
  );

  const ensureRepository = useCallback(
    (repositoryPath: string) => requestRepository(repositoryPath),
    [requestRepository],
  );

  const retryRepository = useCallback(
    (repositoryPath: string) => requestRepository(repositoryPath, true),
    [requestRepository],
  );

  const cancelScheduledRefresh = useCallback(() => {
    const timeoutId = scheduledRefreshTimeoutRef.current;
    scheduledRefreshTimeoutRef.current = null;
    pendingRefreshPathsRef.current.clear();
    if (timeoutId !== null) scheduler.clearTimer(timeoutId);
  }, [scheduler]);

  const scheduleRefresh = useCallback(
    (repositoryPath: string) => {
      if (!requestedRepositoryKeysRef.current.has(normalizeRepositoryPath(repositoryPath))) return;
      pendingRefreshPathsRef.current.add(repositoryPath);
      if (scheduledRefreshTimeoutRef.current !== null) return;

      scheduledRefreshTimeoutRef.current = scheduler.setTimer(() => {
        scheduledRefreshTimeoutRef.current = null;
        const targets = [...pendingRefreshPathsRef.current];
        pendingRefreshPathsRef.current.clear();
        for (const target of targets) void requestRepository(target, true);
      }, REFRESH_DEBOUNCE_MS);
    },
    [requestRepository, scheduler],
  );

  const repositoryPathsKey = [...new Set(repositoryPaths.map(normalizeRepositoryPath))].join("\0");
  const activeRepositoryKey = activeRepositoryPath
    ? normalizeRepositoryPath(activeRepositoryPath)
    : "";

  useEffect(() => {
    cancelScheduledRefresh();
    const keys = repositoryPathsKey ? repositoryPathsKey.split("\0") : [];
    for (const key of [...generationsRef.current.keys()]) {
      if (keys.includes(key)) continue;
      generationsRef.current.set(key, (generationsRef.current.get(key) ?? 0) + 1);
    }
    for (const key of [...requestedRepositoryKeysRef.current]) {
      if (keys.includes(key)) continue;
      requestedRepositoryKeysRef.current.delete(key);
      cancelRepositoryOperations(key);
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

    if (activeRepositoryKey) void requestRepository(activeRepositoryKey);
  }, [
    activeRepositoryKey,
    cancelRepositoryOperations,
    cancelScheduledRefresh,
    repositoryPathsKey,
    requestRepository,
  ]);

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
      cancelAllOperations();
      generationsRef.current.clear();
      requestedRepositoryKeysRef.current.clear();
    },
    [cancelAllOperations, cancelScheduledRefresh],
  );

  return {
    referencesByRepository: state.referencesByRepository,
    errorsByRepository: state.errorsByRepository,
    isLoading: state.isLoading,
    error: state.error,
    ensureRepository,
    retryRepository,
  };
}
