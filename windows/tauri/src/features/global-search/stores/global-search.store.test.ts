import { describe, expect, test } from "bun:test";
import type { FileSearchResult } from "@/features/file-search/lib/file-search-api";
import type { SearchFilesResponse } from "@/features/file-search/lib/file-search-api";
import { createGlobalSearchStore, useGlobalSearchStore } from "./global-search.store";

const result: FileSearchResult = {
  file_path: "C:/workspace/src/main.ts",
  matches: [
    {
      line_number: 1,
      line_content: "const retained = true;",
      column_start: 6,
      column_end: 14,
    },
  ],
  total_matches: 1,
};

const response: SearchFilesResponse = {
  results: [result],
  total_files: 12,
  files_with_matches: 1,
  searched_files: 12,
  searchable_files: 12,
  indexed_files: 12,
  next_file_offset: 0,
  has_more: false,
  is_indexing: false,
  regex_fallback_error: null,
};

describe("global search session store", () => {
  test("retains a completed search snapshot after its view unmounts", () => {
    const store = useGlobalSearchStore.getStore("search-retention");
    store.getState().actions.setQuery("retained");
    store.getState().actions.completeSearch("completed-search-key", response);

    expect(store.getState().query).toBe("retained");
    expect(store.getState().results).toEqual([result]);
    expect(store.getState().resultsSearchKey).not.toBeNull();
  });

  test("isolates search sessions by workspace", () => {
    const first = useGlobalSearchStore.getStore("search-workspace-a");
    const second = useGlobalSearchStore.getStore("search-workspace-b");
    first.getState().actions.setQuery("first workspace");

    expect(first.getState().query).toBe("first workspace");
    expect(second.getState().query).toBe("");
  });

  test("rejects stale request generations after a newer search begins", () => {
    const store = useGlobalSearchStore.getStore("search-generation");
    const first = store.getState().actions.beginSearch();
    const second = store.getState().actions.beginSearch();

    expect(store.getState().actions.isCurrentRequest(first)).toBe(false);
    expect(store.getState().actions.isCurrentRequest(second)).toBe(true);
  });

  test("keeps search lifecycle fields consistent across semantic actions", () => {
    const store = createGlobalSearchStore();
    const generation = store.getState().actions.beginSearch();
    store.getState().actions.completeSearch("completed-search-key", response);

    expect(store.getState()).toMatchObject({
      requestGeneration: generation,
      results: [result],
      resultsSearchKey: "completed-search-key",
      searchedFiles: 12,
      searchableFiles: 12,
      isIndexing: false,
      error: null,
    });

    store.getState().actions.clearSearch();

    expect(store.getState()).toMatchObject({
      requestGeneration: generation + 1,
      results: [],
      resultsSearchKey: null,
      searchedFiles: 0,
      searchableFiles: 0,
      isIndexing: false,
      error: null,
    });
  });
});
