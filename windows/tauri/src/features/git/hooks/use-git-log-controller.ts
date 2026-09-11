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
import {
  reconcileGitLogReference,
  selectedReferenceAfterRemoval,
  shouldRefreshGitLogForChange,
} from "../utils/git-log-refresh";

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
  const scheduledRefreshTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const historyRef = useRef(history);
  const selectedReferenceRef = useRef(selectedReference);
  const repoPathRef = useRef(repoPath);
  const stateRepoPathRef = useRef(repoPath);

  historyRef.current = history;
  selectedReferenceRef.current = selectedReference;
  repoPathRef.current = repoPath;
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

  const cancelScheduledRefresh = useCallback(() => {
    const timeoutId = scheduledRefreshTimeoutRef.current;
    scheduledRefreshTimeoutRef.current = null;
    if (timeoutId !== null) clearTimeout(timeoutId);
  }, []);

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
      if (!repoPath || repoPathRef.current !== repoPath) return;

      const requestId = ++requestIdRef.current;
      const isStaleRequest = () =>
        requestId !== requestIdRef.current || repoPathRef.current !== repoPath;
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
        const [references, initialPage] = await Promise.all([
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
        if (isStaleRequest()) {
          if (initialPage?.nextCursor) {
            void closeGitHistoryCursor(repoPath, initialPage.nextCursor);
          } else if (cursor) {
            void closeGitHistoryCursor(repoPath, cursor);
          }
          return;
        }
        const referenceRefresh = reconcileGitLogReference(
          reference,
          references?.references ?? null,
        );
        let page = initialPage;
        let resolvedReference = referenceRefresh.reference;
        if (!cursor && referenceRefresh.isMissing) {
          if (page?.nextCursor) void closeGitHistoryCursor(repoPath, page.nextCursor);
          const fallbackOperationId = `${operationPrefix}-fallback-page`;
          activeOperationIdsRef.current.add(fallbackOperationId);
          try {
            page = await getGitHistoryPage(
              repoPath,
              undefined,
              COMMITS_PER_PAGE,
              fallbackOperationId,
            );
            if (page) resolvedReference = null;
          } finally {
            activeOperationIdsRef.current.delete(fallbackOperationId);
          }
        }
        if (isStaleRequest()) {
          if (page?.nextCursor) void closeGitHistoryCursor(repoPath, page.nextCursor);
          else if (cursor) void closeGitHistoryCursor(repoPath, cursor);
          return;
        }
        if (!page) {
          if (cursor) void closeGitHistoryCursor(repoPath, cursor);
          setLoadState("failed");
          setError(t("git.historyLoadRepositoryFailed"));
          return;
        }

        if (resolvedReference !== reference) {
          selectedReferenceRef.current = resolvedReference;
          setSelectedReferenceState(resolvedReference);
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
        if (isStaleRequest()) {
          if (cursor) void closeGitHistoryCursor(repoPath, cursor);
          return;
        }
        if (cursor) void closeGitHistoryCursor(repoPath, cursor);
        setLoadState("failed");
        setError(loadError instanceof Error ? loadError.message : t("git.historyLoadFailed"));
      } finally {
        activeOperationIdsRef.current.delete(pageOperationId);
        activeOperationIdsRef.current.delete(referencesOperationId);
        if (!isStaleRequest()) setIsLoadingMore(false);
      }
    },
    [cancelActiveOperations, closeActiveCursor, repoPath, t],
  );

  useEffect(() => {
    requestIdRef.current += 1;
    cancelScheduledRefresh();
    cancelActiveOperations();
    closeActiveCursor();
    stateRepoPathRef.current = repoPath;
    historyRef.current = EMPTY_HISTORY;
    selectedReferenceRef.current = null;
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
      cancelScheduledRefresh();
      cancelActiveOperations();
      closeActiveCursor();
    };
  }, [cancelActiveOperations, cancelScheduledRefresh, closeActiveCursor, load, repoPath]);

  const selectReference = useCallback(
    (reference: GitReference | null) => {
      if (repoPathRef.current !== repoPath) return;
      selectedReferenceRef.current = reference;
      setSelectedReferenceState(reference);
      closeActiveCursor();
      void load({ reference });
    },
    [closeActiveCursor, load, repoPath],
  );

  const forgetReference = useCallback(
    (reference: Pick<GitReference, "fullName">) => {
      if (repoPathRef.current !== repoPath) return;
      const currentReference = selectedReferenceRef.current;
      const nextReference = selectedReferenceAfterRemoval(currentReference, reference.fullName);
      if (nextReference === currentReference) return;
      selectedReferenceRef.current = nextReference;
      setSelectedReferenceState(nextReference);
    },
    [repoPath],
  );

  const refresh = useCallback(() => {
    if (repoPathRef.current !== repoPath) return Promise.resolve();
    cancelScheduledRefresh();
    closeActiveCursor();
    return load({ reference: selectedReferenceRef.current });
  }, [cancelScheduledRefresh, closeActiveCursor, load, repoPath]);

  useEffect(() => {
    if (!repoPath) return;

    const unsubscribe = subscribeToGitChanges((change) => {
      if (!shouldRefreshGitLogForChange(change, repoPath)) return;
      cancelScheduledRefresh();
      scheduledRefreshTimeoutRef.current = setTimeout(() => {
        scheduledRefreshTimeoutRef.current = null;
        void refresh();
      }, 100);
    });

    return () => {
      unsubscribe();
      cancelScheduledRefresh();
    };
  }, [cancelScheduledRefresh, refresh, repoPath]);

  const loadMore = useCallback(() => {
    if (repoPathRef.current !== repoPath) return Promise.resolve();
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
  }, [isLoadingMore, load, repoPath]);

  const stateBelongsToRepository = stateRepoPathRef.current === repoPath;

  return {
    history: stateBelongsToRepository ? history : EMPTY_HISTORY,
    loadState: stateBelongsToRepository ? loadState : repoPath ? "loading" : "idle",
    error: stateBelongsToRepository ? error : null,
    selectedReference: stateBelongsToRepository ? selectedReference : null,
    isLoadingMore: stateBelongsToRepository ? isLoadingMore : false,
    selectReference,
    forgetReference,
    refresh,
    loadMore,
  };
}
