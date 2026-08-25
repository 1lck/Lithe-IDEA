import { afterAll, beforeEach, describe, expect, mock, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import type { SearchFilesResponse } from "@/features/file-search/lib/file-search-api";
import { installHappyDom } from "@/test-utils/happy-dom";

const restoreDom = installHappyDom();
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

const { useContentSearch } = await import("./use-content-search");
const { workspaceRuntimeRegistry } =
  await import("@/features/workspace/runtime/workspace-runtime-registry");

type SearchHook = ReturnType<typeof useContentSearch>;

function mountSearchProbe(onRender: (search: SearchHook) => void): {
  root: Root;
  render: () => Promise<void>;
} {
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);

  function Probe(): ReactNode {
    onRender(useContentSearch());
    return null;
  }

  return {
    root,
    render: async () => {
      await act(async () => {
        root.render(<Probe />);
      });
    },
  };
}

beforeEach(() => {
  workspaceRuntimeRegistry.resetForTests();
  searchFilesContent.mockClear();
});

afterAll(() => {
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

    await act(async () => {
      firstMount.root.unmount();
    });

    const secondMount = mountSearchProbe((search) => {
      currentSearch = search;
    });
    await secondMount.render();

    expect(readCurrentSearch().query).toBe("retained");
    expect(readCurrentSearch().results).toEqual(response.results);
    expect(searchFilesContent).toHaveBeenCalledTimes(1);

    await act(async () => {
      secondMount.root.unmount();
    });
  });
});
