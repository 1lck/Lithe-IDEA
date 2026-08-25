import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useDebounce } from "use-debounce";
import type { FileEntry } from "@/features/file-system/types/app.types";
import type {
  FileSearchResult,
  SearchFilesResponse,
} from "@/features/file-search/lib/file-search-api";
import { fffScanStatus, searchFilesContent } from "@/features/file-search/lib/file-search-api";
import { getNativeWorkspaceRootPaths } from "@/features/file-search/utils/file-search-paths";
import {
  loadProviderSearchFiles,
  searchProviderFilesContent,
} from "../services/provider-content-search";
import { CONTENT_SEARCH_PAGE_SIZE, SEARCH_DEBOUNCE_DELAY } from "../constants/limits";
import { mergeSearchResults } from "../utils/content-search-results";
import { createPathFilterPredicate } from "../utils/path-filters";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { useGlobalSearchStore } from "../stores/global-search.store";

export type { ContentSearchOptions } from "../types/global-search.types";

export type ContentSearchAvailability = "ready" | "no-workspace" | "unsupported";

const CONTEXT_LINES = 2;
const INDEX_STATUS_POLL_DELAY = 150;
const PROVIDER_FILE_CACHE_TTL = 2_000;

const canUseContentSearch = (rootPath: string | null | undefined): rootPath is string =>
  Boolean(rootPath) &&
  !rootPath?.startsWith("remote://") &&
  !rootPath?.startsWith("wsl://") &&
  !rootPath?.startsWith("diff://");

const canUseProviderContentSearch = (rootPath: string | null | undefined): rootPath is string =>
  typeof rootPath === "string" && rootPath.startsWith("wsl://");

function getSearchAvailability(rootPath: string | null | undefined): ContentSearchAvailability {
  if (!rootPath) return "no-workspace";
  if (canUseContentSearch(rootPath) || canUseProviderContentSearch(rootPath)) return "ready";
  return "unsupported";
}

function getErrorMessage(error: unknown): string {
  if (error instanceof Error) return error.message;
  if (typeof error === "string") return error;
  return "Unknown search error";
}

function hasPathFilters(includeQuery: string, excludeQuery: string): boolean {
  return Boolean(includeQuery.trim() || excludeQuery.trim());
}

function mergeSearchResponses(
  previous: SearchFilesResponse | null,
  next: SearchFilesResponse,
  results: FileSearchResult[],
): SearchFilesResponse {
  if (!previous) {
    return {
      ...next,
      results,
      files_with_matches: results.length,
    };
  }

  const mergedResults = mergeSearchResults(previous.results, results);
  return {
    ...next,
    results: mergedResults,
    searched_files: previous.searched_files + next.searched_files,
    files_with_matches: mergedResults.length,
    regex_fallback_error: previous.regex_fallback_error ?? next.regex_fallback_error,
  };
}

interface ProviderFileCache {
  rootPath: string;
  expiresAt: number;
  promise: Promise<FileEntry[]>;
}

interface ProviderSearchSession {
  searchKey: string;
  promise: Promise<FileEntry[]>;
}

export const useContentSearch = () => {
  const rootFolderPath = useFileSystemStore((state) => state.rootFolderPath);
  const workspaceFolders = useFileSystemStore((state) => state.workspaceFolders);
  const nativeRootPaths = useMemo(
    () => getNativeWorkspaceRootPaths(rootFolderPath, workspaceFolders),
    [rootFolderPath, workspaceFolders],
  );
  const searchSession = useGlobalSearchStore((state) => state);
  const {
    query,
    results: rawResults,
    error,
    searchWarning,
    nextFileOffset,
    hasMoreResults,
    searchedFiles,
    searchableFiles,
    isIndexing,
    indexedFiles,
    scannedFiles,
    includeQuery,
    excludeQuery,
    searchOptions,
    resultsSearchKey,
    requestGeneration,
    actions: searchActions,
  } = searchSession;
  const [debouncedQuery] = useDebounce(query, SEARCH_DEBOUNCE_DELAY);
  const [isSearching, setIsSearching] = useState(false);
  const [isLoadingMore, setIsLoadingMore] = useState(false);
  const [debouncedIncludeQuery] = useDebounce(includeQuery, SEARCH_DEBOUNCE_DELAY);
  const [debouncedExcludeQuery] = useDebounce(excludeQuery, SEARCH_DEBOUNCE_DELAY);
  const providerFileCacheRef = useRef<ProviderFileCache | null>(null);
  const providerSearchSessionRef = useRef<ProviderSearchSession | null>(null);
  const availability = getSearchAvailability(rootFolderPath);
  const searchKey = useMemo(
    () =>
      [
        nativeRootPaths.join("\n") || rootFolderPath || "",
        debouncedQuery,
        debouncedIncludeQuery,
        debouncedExcludeQuery,
        Number(searchOptions.caseSensitive),
        Number(searchOptions.wholeWord),
        Number(searchOptions.useRegex),
      ].join("\0"),
    [
      debouncedExcludeQuery,
      debouncedIncludeQuery,
      debouncedQuery,
      nativeRootPaths,
      rootFolderPath,
      searchOptions.caseSensitive,
      searchOptions.useRegex,
      searchOptions.wholeWord,
    ],
  );
  const isSearchPending =
    query !== debouncedQuery ||
    includeQuery !== debouncedIncludeQuery ||
    excludeQuery !== debouncedExcludeQuery ||
    (Boolean(debouncedQuery.trim()) && availability === "ready" && resultsSearchKey !== searchKey);

  const getProviderFiles = useCallback(
    (rootPath: string, currentSearchKey: string, fileOffset: number) => {
      const currentSession = providerSearchSessionRef.current;
      if (fileOffset > 0 && currentSession?.searchKey === currentSearchKey) {
        return currentSession.promise;
      }

      const now = Date.now();
      const cached = providerFileCacheRef.current;
      const promise =
        cached && cached.rootPath === rootPath && cached.expiresAt > now
          ? cached.promise
          : loadProviderSearchFiles();

      if (promise !== cached?.promise) {
        providerFileCacheRef.current = {
          rootPath,
          expiresAt: now + PROVIDER_FILE_CACHE_TTL,
          promise,
        };
      }

      providerSearchSessionRef.current = { searchKey: currentSearchKey, promise };
      return promise;
    },
    [],
  );

  const requestSearchPage = useCallback(
    async (fileOffset: number, currentRequestId: number): Promise<SearchFilesResponse | null> => {
      const searchRootPath = rootFolderPath;
      if (!searchRootPath || availability !== "ready") return null;

      if (canUseProviderContentSearch(searchRootPath)) {
        const files = await getProviderFiles(searchRootPath, searchKey, fileOffset);
        if (!searchActions.isCurrentRequest(currentRequestId)) return null;

        return searchProviderFilesContent({
          files,
          query: debouncedQuery,
          rootFolderPath: searchRootPath,
          options: searchOptions,
          maxResults: CONTENT_SEARCH_PAGE_SIZE,
          fileOffset,
          contextLines: CONTEXT_LINES,
          includeQuery: debouncedIncludeQuery,
          excludeQuery: debouncedExcludeQuery,
          isCancelled: () => !searchActions.isCurrentRequest(currentRequestId),
        });
      }

      return searchFilesContent({
        root_paths: nativeRootPaths,
        query: debouncedQuery,
        case_sensitive: searchOptions.caseSensitive,
        whole_word: searchOptions.wholeWord,
        use_regex: searchOptions.useRegex,
        max_results: CONTENT_SEARCH_PAGE_SIZE,
        file_offset: fileOffset,
        context_lines: CONTEXT_LINES,
      });
    },
    [
      availability,
      debouncedExcludeQuery,
      debouncedIncludeQuery,
      debouncedQuery,
      getProviderFiles,
      nativeRootPaths,
      rootFolderPath,
      searchActions,
      searchKey,
      searchOptions,
    ],
  );

  const requestVisibleSearchPage = useCallback(
    async (fileOffset: number, currentRequestId: number): Promise<SearchFilesResponse | null> => {
      const matchesPathFilters = createPathFilterPredicate(
        rootFolderPath,
        debouncedIncludeQuery,
        debouncedExcludeQuery,
      );
      const shouldSkipEmptyPages = hasPathFilters(debouncedIncludeQuery, debouncedExcludeQuery);
      let response: SearchFilesResponse | null = null;
      let nextOffset = fileOffset;

      while (searchActions.isCurrentRequest(currentRequestId)) {
        const page = await requestSearchPage(nextOffset, currentRequestId);
        if (!page || !searchActions.isCurrentRequest(currentRequestId)) return null;
        if (page.is_indexing) return page;

        const visibleResults = page.results.filter((result) =>
          matchesPathFilters(result.file_path),
        );
        response = mergeSearchResponses(response, page, visibleResults);

        if (!shouldSkipEmptyPages || visibleResults.length > 0 || !page.has_more) {
          return response;
        }

        if (page.next_file_offset <= nextOffset) {
          return {
            ...response,
            has_more: false,
            next_file_offset: 0,
          };
        }

        nextOffset = page.next_file_offset;
      }

      return null;
    },
    [
      debouncedExcludeQuery,
      debouncedIncludeQuery,
      requestSearchPage,
      rootFolderPath,
      searchActions,
    ],
  );

  const performSearch = useCallback(
    async (force = false) => {
      const hasQuery = Boolean(debouncedQuery.trim());

      if (!hasQuery || availability !== "ready") {
        searchActions.clearSearch();
        setIsSearching(false);
        setIsLoadingMore(false);
        return;
      }

      if (!force && resultsSearchKey === searchKey) return;

      const currentRequestId = searchActions.beginSearch();
      setIsSearching(true);
      setIsLoadingMore(false);

      try {
        const response = await requestVisibleSearchPage(0, currentRequestId);
        if (!response || !searchActions.isCurrentRequest(currentRequestId)) return;

        if (response.is_indexing) {
          searchActions.setIndexProgress(true, response.indexed_files, response.indexed_files);
          return;
        }

        searchActions.completeSearch(searchKey, response);
      } catch (searchError) {
        if (!searchActions.isCurrentRequest(currentRequestId)) return;
        console.error("Search error:", searchError);
        searchActions.failSearch(searchKey, `Search failed: ${getErrorMessage(searchError)}`);
      } finally {
        if (searchActions.isCurrentRequest(currentRequestId)) {
          setIsSearching(false);
        }
      }
    },
    [
      availability,
      debouncedQuery,
      requestVisibleSearchPage,
      resultsSearchKey,
      searchActions,
      searchKey,
    ],
  );

  const refreshSearch = useCallback(() => performSearch(true), [performSearch]);

  const loadMoreResults = useCallback(async () => {
    if (
      !debouncedQuery.trim() ||
      availability !== "ready" ||
      !hasMoreResults ||
      nextFileOffset <= 0 ||
      isSearching ||
      isLoadingMore
    ) {
      return;
    }

    const currentRequestId = requestGeneration;
    setIsLoadingMore(true);
    searchActions.beginLoadMore();

    try {
      const response = await requestVisibleSearchPage(nextFileOffset, currentRequestId);
      if (!response || !searchActions.isCurrentRequest(currentRequestId)) return;

      if (response.is_indexing) {
        searchActions.setIndexProgress(true, response.indexed_files, response.indexed_files);
        return;
      }

      searchActions.completeLoadMore(response);
    } catch (searchError) {
      if (!searchActions.isCurrentRequest(currentRequestId)) return;
      console.error("Search error:", searchError);
      searchActions.failLoadMore(`Search failed: ${getErrorMessage(searchError)}`);
    } finally {
      if (searchActions.isCurrentRequest(currentRequestId)) {
        setIsLoadingMore(false);
      }
    }
  }, [
    availability,
    debouncedQuery,
    hasMoreResults,
    isLoadingMore,
    isSearching,
    nextFileOffset,
    requestGeneration,
    requestVisibleSearchPage,
    searchActions,
  ]);

  useEffect(() => {
    if (!isIndexing || !debouncedQuery.trim() || !canUseContentSearch(rootFolderPath)) return;

    const pollingRequestId = requestGeneration;
    let disposed = false;
    let timer: ReturnType<typeof setTimeout> | null = null;
    let failureCount = 0;

    const pollScanStatus = async () => {
      try {
        const status = await fffScanStatus(nativeRootPaths);
        if (disposed || !searchActions.isCurrentRequest(pollingRequestId)) return;

        searchActions.setIndexProgress(
          status.is_scanning,
          status.indexed_files,
          status.scanned_files_count,
        );
        failureCount = 0;

        if (status.is_scanning) {
          timer = setTimeout(pollScanStatus, INDEX_STATUS_POLL_DELAY);
          return;
        }

        void performSearch(true);
      } catch (statusError) {
        if (disposed || !searchActions.isCurrentRequest(pollingRequestId)) return;
        console.error("Search index status error:", statusError);
        failureCount++;
        if (failureCount >= 3) {
          searchActions.failIndexing(
            searchKey,
            `Search indexing failed: ${getErrorMessage(statusError)}`,
          );
          return;
        }
        timer = setTimeout(pollScanStatus, INDEX_STATUS_POLL_DELAY);
      }
    };

    timer = setTimeout(pollScanStatus, INDEX_STATUS_POLL_DELAY);

    return () => {
      disposed = true;
      if (timer) clearTimeout(timer);
    };
  }, [
    debouncedQuery,
    isIndexing,
    nativeRootPaths,
    performSearch,
    requestGeneration,
    rootFolderPath,
    searchActions,
    searchKey,
  ]);

  useEffect(() => {
    void performSearch();
  }, [performSearch]);

  useEffect(() => {
    if (providerFileCacheRef.current?.rootPath !== rootFolderPath) {
      providerFileCacheRef.current = null;
      providerSearchSessionRef.current = null;
    }
  }, [rootFolderPath]);

  return {
    query,
    setQuery: searchActions.setQuery,
    debouncedQuery,
    results: rawResults,
    isSearching,
    isSearchPending,
    isLoadingMore,
    error,
    searchWarning,
    hasMoreResults,
    searchedFiles,
    searchableFiles,
    isIndexing,
    indexedFiles,
    scannedFiles,
    rootFolderPath,
    availability,
    searchKey,
    searchOptions,
    setSearchOption: searchActions.setSearchOption,
    includeQuery,
    setIncludeQuery: searchActions.setIncludeQuery,
    excludeQuery,
    setExcludeQuery: searchActions.setExcludeQuery,
    refreshSearch,
    loadMoreResults,
  };
};
