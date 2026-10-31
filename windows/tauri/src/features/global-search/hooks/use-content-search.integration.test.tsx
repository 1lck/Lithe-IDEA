import { afterAll, afterEach, beforeEach, describe, expect, mock, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import type { SearchFilesResponse } from "@/features/file-search/lib/file-search-api";
import { installHappyDom } from "@/test-utils/happy-dom";

const restoreDom = installHappyDom();
const previousActEnvironment =
  (globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean })
    .IS_REACT_ACT_ENVIRONMENT;
(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT =
  true;

const response: SearchFilesResponse = {
  results: [
    {
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
    },
  ],
  total_files: 1,
  searched_files: 1,
  searchable_files: 1,
  files_with_matches: 1,
  next_file_offset: 0,
  has_more: false,
  is_indexing: false,
  indexed_files: 1,
  regex_fallback_error: null,
};

const searchFilesContent = mock(async () => response);
const fileSystemState = { rootFolderPath: "C:/workspace", workspaceFolders: [] as never[] };

mock.module("use-debounce", () => ({
  useDebounce: <Value,>(value: Value) => [value] as const,
}));
mock.module("@/features/file-system/stores/file-system.store", () => ({
  useFileSystemStore: <Value,>(
    selector: (state: { rootFolderPath: string; workspaceFolders: never[] }) => Value,
  ) => selector(fileSystemState),
}));
mock.module("@/features/file-search/lib/file-search-api", () => ({
  searchFilesContent,
  fffScanStatus: mock(async () => ({
    is_scanning: false,
    scanned_files_count: 1,
    indexed_files: 1,
    is_watcher_ready: true,
    is_warmup_complete: true,
  })),
}));
mock.module("../services/provider-content-search", () => ({
  loadProviderSearchFiles: mock(async () => []),
  searchProviderFilesContent: mock(async () => response),
}));
mock.module("@/features/settings/stores/settings.store", () => ({
  useSettingsStore: <Value,>(
    selector: (state: { settings: { displayLanguage: "en-US" } }) => Value,
  ) => selector({ settings: { displayLanguage: "en-US" } }),
}));

const { useContentSearch } = await import("./use-content-search");
const { GlobalSearchState } = await import("../components/global-search-state");
const { LocaleProvider } = await import("@/i18n/locale-provider");
const { createTranslator } = await import("@/i18n/locale");
const { IndexingSettingsError, indexingSettingsStorageKey, readIndexingSettings } =
  await import("@/features/file-explorer/stores/workspace-indexing");
const { workspaceRuntimeRegistry } =
  await import("@/features/workspace/runtime/workspace-runtime-registry");

type SearchHook = ReturnType<typeof useContentSearch>;
const mountedProbes = new Map<Root, HTMLElement>();

function mountSearchProbe(onRender: (search: SearchHook) => void): {
  root: Root;
  container: HTMLElement;
  render: (language?: "en-US" | "zh-CN") => Promise<void>;
  unmount: () => Promise<void>;
} {
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  mountedProbes.set(root, container);

  function Probe(): ReactNode {
    const search = useContentSearch();
    onRender(search);
    return (
      <GlobalSearchState
        availability={search.availability}
        query={search.query}
        debouncedQuery={search.debouncedQuery}
        busyLabel={null}
        showBusy={false}
        error={search.error}
        hasFileFilters={false}
        onRetry={search.refreshSearch}
      />
    );
  }

  return {
    root,
    container,
    render: async (language = "en-US") => {
      await act(async () => {
        root.render(<LocaleProvider language={language}><Probe /></LocaleProvider>);
      });
    },
    unmount: async () => {
      await act(async () => root.unmount());
      mountedProbes.delete(root);
      container.remove();
    },
  };
}

beforeEach(() => {
  workspaceRuntimeRegistry.resetForTests();
  searchFilesContent.mockReset().mockResolvedValue(response);
  window.localStorage.clear();
});

afterEach(async () => {
  for (const [root, container] of mountedProbes) {
    await act(async () => root.unmount());
    container.remove();
  }
  mountedProbes.clear();
});

afterAll(() => {
  (globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean })
    .IS_REACT_ACT_ENVIRONMENT = previousActEnvironment;
  restoreDom();
});

describe("content search lifecycle", () => {
  test("retains completed results without searching again after remount", async () => {
    let currentSearch: SearchHook | null = null;
    const readCurrentSearch = (): SearchHook => {
      if (!currentSearch) throw new Error("Search probe has not rendered");
      return currentSearch;
    };
    const firstMount = mountSearchProbe((search) => {
      currentSearch = search;
    });
    await firstMount.render();

    await act(async () => {
      readCurrentSearch().setQuery("retained");
    });
    await act(async () => {});

    expect(searchFilesContent).toHaveBeenCalledTimes(1);
    expect(readCurrentSearch().results).toEqual(response.results);

    await firstMount.unmount();

    const secondMount = mountSearchProbe((search) => {
      currentSearch = search;
    });
    await secondMount.render();

    expect(readCurrentSearch().query).toBe("retained");
    expect(readCurrentSearch().results).toEqual(response.results);
    expect(searchFilesContent).toHaveBeenCalledTimes(1);

    await secondMount.unmount();
  });

  test("corrupt indexing preferences render in the current language without being overwritten", async () => {
    const storageKey = indexingSettingsStorageKey("C:/workspace");
    window.localStorage.setItem(storageKey, "{}");
    searchFilesContent.mockImplementation(async () => {
      readIndexingSettings("C:/workspace");
      return response;
    });
    let current: SearchHook | undefined;
    const probe = mountSearchProbe((search) => { current = search; });
    await probe.render();
    await act(async () => current!.setQuery("retained"));

    expect(current!.error).toEqual({ kind: "indexing", code: "invalidSettings" });
    expect(probe.container.textContent).toContain(createTranslator("en-US")("indexing.invalidSettings"));
    expect(probe.container.textContent).not.toContain("invalidSettings");
    await probe.render("zh-CN");
    expect(probe.container.textContent).toContain(createTranslator("zh-CN")("indexing.invalidSettings"));
    expect(searchFilesContent).toHaveBeenCalledTimes(1);
    expect(window.localStorage.getItem(storageKey)).toBe("{}");
  });

  test("load-more indexing failures retain results and translate without another search", async () => {
    searchFilesContent
      .mockResolvedValueOnce({ ...response, has_more: true, next_file_offset: 1 })
      .mockRejectedValueOnce(new IndexingSettingsError("readFailed"));
    let current: SearchHook | undefined;
    const probe = mountSearchProbe((search) => { current = search; });
    await probe.render("zh-CN");
    await act(async () => current!.setQuery("retained"));
    await act(async () => { await current!.loadMoreResults(); });

    expect(current!.results).toEqual(response.results);
    expect(current!.error).toEqual({ kind: "indexing", code: "readFailed" });
    expect(probe.container.textContent).toContain(createTranslator("zh-CN")("indexing.readFailed"));
    await probe.render("en-US");
    expect(probe.container.textContent).toContain(createTranslator("en-US")("indexing.readFailed"));
    expect(searchFilesContent).toHaveBeenCalledTimes(2);
  });
});
