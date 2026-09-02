import { useCallback, useEffect, useRef, useState } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import {
  cancelGitHistoryOperation,
  closeGitHistoryCursor,
  getGitHistoryPage,
  getGitReferences,
} from "../api/git-commits-api";
import { subscribeToGitChanges } from "../events/git-events";
import type { GitHistorySnapshot, GitReference } from "../types/git.types";
import { shouldRefreshGitLogForChange } from "../utils/git-log-refresh";

type GitLogLoadState = "idle" | "loading" | "ready" | "failed";

const COMMITS_PER_PAGE = 50;
const MAX_COMMITS = 5_000;
let nextControllerId = 0;
const EMPTY_HISTORY: GitHistorySnapshot = {
  references: [],
  recentReferences: [],
  commits: [],
  hasMore: false,
};

export function useGitLogController(repoPath: string | null) {
  const { t } = useTranslation();
  const [history, setHistory] = useState<GitHistorySnapshot>(EMPTY_HISTORY);
  const [loadState, setLoadState] = useState<GitLogLoadState>("idle");
  const [error, setError] = useState<string | null>(null);
  const [selectedReference, setSelectedReferenceState] = useState<GitReference | null>(null);
  const [isLoadingMore, setIsLoadingMore] = useState(false);
  const requestIdRef = useRef(0);
  const controllerIdRef = useRef<number | null>(null);
  const activeCursorRef = useRef<string | null>(null);
  const activeOperationIdsRef = useRef(new Set<string>());
  const historyRef = useRef(history);
  const selectedReferenceRef = useRef(selectedReference);

  historyRef.current = history;
  selectedReferenceRef.current = selectedReference;
  if (controllerIdRef.current === null) controllerIdRef.current = ++nextControllerId;

  const cancelActiveOperations = useCallback(() => {
    for (const operationId of activeOperationIdsRef.current) {
      void cancelGitHistoryOperation(operationId);
    }
    activeOperationIdsRef.current.clear();
  }, []);

  const closeActiveCursor = useCallback(() => {
    const cursor = activeCursorRef.current;
    activeCursorRef.current = null;
    if (repoPath && cursor) void closeGitHistoryCursor(repoPath, cursor);
  }, [repoPath]);

  const load = useCallback(
    async ({
      reference,
      cursor,
      loadingMore = false,
      refreshReferences = true,
    }: {
      reference: GitReference | null;
      cursor?: string;
      loadingMore?: boolean;
      refreshReferences?: boolean;
    }) => {
      if (!repoPath) return;

      const requestId = ++requestIdRef.current;
      cancelActiveOperations();
      if (!loadingMore) closeActiveCursor();
      const operationPrefix = `git-log-${controllerIdRef.current}-${requestId}`;
      const pageOperationId = `${operationPrefix}-page`;
      const referencesOperationId = `${operationPrefix}-references`;
      activeOperationIdsRef.current.add(pageOperationId);
      if (refreshReferences) activeOperationIdsRef.current.add(referencesOperationId);
      setError(null);
      if (loadingMore) setIsLoadingMore(true);
      else setLoadState("loading");

      try {
        const [references, page] = await Promise.all([
          refreshReferences
            ? getGitReferences(repoPath, referencesOperationId)
            : Promise.resolve(null),
          getGitHistoryPage(
            repoPath,
            cursor,
            COMMITS_PER_PAGE,
            pageOperationId,
            reference?.fullName,
          ),
        ]);
        if (requestId !== requestIdRef.current) {
          if (page?.nextCursor) void closeGitHistoryCursor(repoPath, page.nextCursor);
          return;
        }
        if (!page) {
          setLoadState("failed");
          setError(t("git.historyLoadRepositoryFailed"));
          return;
        }

        setHistory((current) => {
          const existingHashes = loadingMore
            ? new Set(current.commits.map((commit) => commit.hash))
            : new Set<string>();
          const commits = loadingMore
            ? [
                ...current.commits,
                ...page.commits.filter((commit) => !existingHashes.has(commit.hash)),
              ]
            : page.commits;
          return {
            references: references?.references ?? current.references,
            recentReferences: references?.recentReferences ?? current.recentReferences,
            commits,
            hasMore: page.hasMore && commits.length < MAX_COMMITS,
          };
        });
        activeCursorRef.current = page.nextCursor ?? null;
        setLoadState("ready");
      } catch (loadError) {
        if (requestId !== requestIdRef.current) return;
        setLoadState("failed");
        setError(loadError instanceof Error ? loadError.message : t("git.historyLoadFailed"));
      } finally {
        activeOperationIdsRef.current.delete(pageOperationId);
        activeOperationIdsRef.current.delete(referencesOperationId);
        if (requestId === requestIdRef.current) setIsLoadingMore(false);
      }
    },
    [cancelActiveOperations, closeActiveCursor, repoPath, t],
  );

  useEffect(() => {
    requestIdRef.current += 1;
    cancelActiveOperations();
    closeActiveCursor();
    setHistory(EMPTY_HISTORY);
    setSelectedReferenceState(null);
    setIsLoadingMore(false);
    setError(null);

    if (!repoPath) {
      setLoadState("idle");
      return;
    }
    void load({ reference: null });

    return () => {
      requestIdRef.current += 1;
      cancelActiveOperations();
      closeActiveCursor();
    };
  }, [cancelActiveOperations, closeActiveCursor, load, repoPath]);

  const selectReference = useCallback(
    (reference: GitReference | null) => {
      selectedReferenceRef.current = reference;
      setSelectedReferenceState(reference);
      closeActiveCursor();
      void load({ reference });
    },
    [closeActiveCursor, load],
  );

  const refresh = useCallback(() => {
    closeActiveCursor();
    return load({ reference: selectedReferenceRef.current });
  }, [closeActiveCursor, load]);

  useEffect(() => {
    if (!repoPath) return;

    let timeoutId: ReturnType<typeof setTimeout> | null = null;
    const unsubscribe = subscribeToGitChanges((change) => {
      if (!shouldRefreshGitLogForChange(change, repoPath)) return;
      if (timeoutId) clearTimeout(timeoutId);
      timeoutId = setTimeout(() => void refresh(), 100);
    });

    return () => {
      unsubscribe();
      if (timeoutId) clearTimeout(timeoutId);
    };
  }, [refresh, repoPath]);

  const loadMore = useCallback(() => {
    const currentHistory = historyRef.current;
    const cursor = activeCursorRef.current;
    if (!currentHistory.hasMore || cursor === null || isLoadingMore) return Promise.resolve();
    activeCursorRef.current = null;
    return load({
      reference: selectedReferenceRef.current,
      cursor,
      loadingMore: true,
      refreshReferences: false,
    });
  }, [isLoadingMore, load]);

  return {
    history,
    loadState,
    error,
    selectedReference,
    isLoadingMore,
    selectReference,
    refresh,
    loadMore,
  };
}
