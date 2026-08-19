import { useCallback, useEffect, useRef, useState } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { getGitHistory } from "../api/git-commits-api";
import { subscribeToGitChanges } from "../events/git-events";
import type { GitHistorySnapshot, GitReference } from "../types/git.types";
import { shouldRefreshGitLogForChange } from "../utils/git-log-refresh";

type GitLogLoadState = "idle" | "loading" | "ready" | "failed";

const COMMITS_PER_PAGE = 50;
const MAX_COMMITS = 5_000;
const EMPTY_HISTORY: GitHistorySnapshot = { references: [], commits: [], hasMore: false };

export function useGitLogController(repoPath: string | null) {
  const { t } = useTranslation();
  const [history, setHistory] = useState<GitHistorySnapshot>(EMPTY_HISTORY);
  const [loadState, setLoadState] = useState<GitLogLoadState>("idle");
  const [error, setError] = useState<string | null>(null);
  const [selectedReference, setSelectedReferenceState] = useState<GitReference | null>(null);
  const [isLoadingMore, setIsLoadingMore] = useState(false);
  const requestIdRef = useRef(0);
  const historyRef = useRef(history);
  const selectedReferenceRef = useRef(selectedReference);

  historyRef.current = history;
  selectedReferenceRef.current = selectedReference;

  const load = useCallback(
    async ({
      reference,
      limit,
      loadingMore = false,
    }: {
      reference: GitReference | null;
      limit: number;
      loadingMore?: boolean;
    }) => {
      if (!repoPath) return;

      const requestId = ++requestIdRef.current;
      setError(null);
      if (loadingMore) setIsLoadingMore(true);
      else setLoadState("loading");

      try {
        const snapshot = await getGitHistory(repoPath, limit, reference?.fullName);
        if (requestId !== requestIdRef.current) return;
        if (!snapshot) {
          setLoadState("failed");
          setError(t("git.historyLoadRepositoryFailed"));
          return;
        }

        setHistory({
          ...snapshot,
          hasMore: snapshot.hasMore && limit < MAX_COMMITS,
        });
        setLoadState("ready");
      } catch (loadError) {
        if (requestId !== requestIdRef.current) return;
        setLoadState("failed");
        setError(loadError instanceof Error ? loadError.message : t("git.historyLoadFailed"));
      } finally {
        if (requestId === requestIdRef.current) setIsLoadingMore(false);
      }
    },
    [repoPath, t],
  );

  useEffect(() => {
    requestIdRef.current += 1;
    setHistory(EMPTY_HISTORY);
    setSelectedReferenceState(null);
    setIsLoadingMore(false);
    setError(null);

    if (!repoPath) {
      setLoadState("idle");
      return;
    }
    void load({ reference: null, limit: COMMITS_PER_PAGE });

    return () => {
      requestIdRef.current += 1;
    };
  }, [load, repoPath]);

  const selectReference = useCallback(
    (reference: GitReference | null) => {
      selectedReferenceRef.current = reference;
      setSelectedReferenceState(reference);
      void load({ reference, limit: COMMITS_PER_PAGE });
    },
    [load],
  );

  const refresh = useCallback(() => {
    const limit = Math.max(COMMITS_PER_PAGE, historyRef.current.commits.length);
    return load({ reference: selectedReferenceRef.current, limit });
  }, [load]);

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
    if (!currentHistory.hasMore || isLoadingMore) return Promise.resolve();
    const limit = Math.min(currentHistory.commits.length + COMMITS_PER_PAGE, MAX_COMMITS);
    return load({ reference: selectedReferenceRef.current, limit, loadingMore: true });
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
