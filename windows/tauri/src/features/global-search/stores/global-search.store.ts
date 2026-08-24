import { createStore } from "zustand/vanilla";
import type {
  FileSearchResult,
  SearchFilesResponse,
} from "@/features/file-search/lib/file-search-api";
import { createWorkspaceScopedStore } from "@/features/workspace/stores/create-workspace-scoped-store";
import type { ContentSearchOptions } from "../types/global-search.types";
import { mergeSearchResults } from "../utils/content-search-results";

const DEFAULT_SEARCH_OPTIONS: ContentSearchOptions = {
  caseSensitive: false,
  wholeWord: false,
  useRegex: false,
};

interface GlobalSearchSessionSnapshot {
  query: string;
  results: FileSearchResult[];
  error: string | null;
  searchWarning: string | null;
  nextFileOffset: number;
  hasMoreResults: boolean;
  searchedFiles: number;
  searchableFiles: number;
  isIndexing: boolean;
  indexedFiles: number;
  scannedFiles: number;
  includeQuery: string;
  excludeQuery: string;
  searchOptions: ContentSearchOptions;
  resultsSearchKey: string | null;
}

interface GlobalSearchSessionState extends GlobalSearchSessionSnapshot {
  requestGeneration: number;
  actions: {
    setQuery: (query: string) => void;
    setIncludeQuery: (query: string) => void;
    setExcludeQuery: (query: string) => void;
    setSearchOption: <Key extends keyof ContentSearchOptions>(
      key: Key,
      value: ContentSearchOptions[Key],
    ) => void;
    clearSearch: () => void;
    beginSearch: () => number;
    completeSearch: (searchKey: string, response: SearchFilesResponse) => void;
    failSearch: (searchKey: string, error: string) => void;
    setIndexProgress: (isIndexing: boolean, indexedFiles: number, scannedFiles: number) => void;
    failIndexing: (searchKey: string, error: string) => void;
    beginLoadMore: () => void;
    completeLoadMore: (response: SearchFilesResponse) => void;
    failLoadMore: (error: string) => void;
    isCurrentRequest: (generation: number) => boolean;
  };
}

const getSearchWarning = (response: SearchFilesResponse) =>
  response.regex_fallback_error ? "Invalid regular expression; showing literal matches" : null;

export const createGlobalSearchStore = () =>
  createStore<GlobalSearchSessionState>()((set, get) => ({
    query: "",
    results: [],
    error: null,
    searchWarning: null,
    nextFileOffset: 0,
    hasMoreResults: false,
    searchedFiles: 0,
    searchableFiles: 0,
    isIndexing: false,
    indexedFiles: 0,
    scannedFiles: 0,
    includeQuery: "",
    excludeQuery: "",
    searchOptions: DEFAULT_SEARCH_OPTIONS,
    resultsSearchKey: null,
    requestGeneration: 0,
    actions: {
      setQuery: (query) => set({ query }),
      setIncludeQuery: (includeQuery) => set({ includeQuery }),
      setExcludeQuery: (excludeQuery) => set({ excludeQuery }),
      setSearchOption: (key, value) =>
        set((state) => ({ searchOptions: { ...state.searchOptions, [key]: value } })),
      clearSearch: () =>
        set((state) => ({
          requestGeneration: state.requestGeneration + 1,
          results: [],
          error: null,
          searchWarning: null,
          nextFileOffset: 0,
          hasMoreResults: false,
          searchedFiles: 0,
          searchableFiles: 0,
          isIndexing: false,
          indexedFiles: 0,
          scannedFiles: 0,
          resultsSearchKey: null,
        })),
      beginSearch: () => {
        const requestGeneration = get().requestGeneration + 1;
        set({
          requestGeneration,
          error: null,
          searchWarning: null,
          results: [],
          nextFileOffset: 0,
          hasMoreResults: false,
          searchedFiles: 0,
          searchableFiles: 0,
          isIndexing: false,
        });
        return requestGeneration;
      },
      completeSearch: (resultsSearchKey, response) =>
        set({
          indexedFiles: response.indexed_files,
          scannedFiles: response.indexed_files,
          results: response.results,
          nextFileOffset: response.next_file_offset,
          hasMoreResults: response.has_more,
          searchedFiles: response.searched_files,
          searchableFiles: response.searchable_files,
          searchWarning: getSearchWarning(response),
          resultsSearchKey,
        }),
      failSearch: (resultsSearchKey, error) =>
        set({
          error,
          results: [],
          nextFileOffset: 0,
          hasMoreResults: false,
          isIndexing: false,
          resultsSearchKey,
        }),
      setIndexProgress: (isIndexing, indexedFiles, scannedFiles) =>
        set({ isIndexing, indexedFiles, scannedFiles }),
      failIndexing: (resultsSearchKey, error) =>
        set({ isIndexing: false, error, resultsSearchKey }),
      beginLoadMore: () => set({ error: null }),
      completeLoadMore: (response) =>
        set((state) => ({
          indexedFiles: response.indexed_files,
          scannedFiles: response.indexed_files,
          results: mergeSearchResults(state.results, response.results),
          nextFileOffset: response.next_file_offset,
          hasMoreResults: response.has_more,
          searchedFiles:
            response.searchable_files > 0
              ? Math.min(state.searchedFiles + response.searched_files, response.searchable_files)
              : state.searchedFiles + response.searched_files,
          searchableFiles: response.searchable_files,
          searchWarning: getSearchWarning(response),
        })),
      failLoadMore: (error) => set({ error }),
      isCurrentRequest: (generation) => get().requestGeneration === generation,
    },
  }));

export const useGlobalSearchStore = createWorkspaceScopedStore(
  "global-search",
  createGlobalSearchStore,
);
