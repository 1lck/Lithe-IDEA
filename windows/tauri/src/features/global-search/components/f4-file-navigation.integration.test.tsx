import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";
import { LocaleProvider } from "@/i18n/locale-provider";
import { createTranslator, type DisplayLanguage } from "@/i18n/locale";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { useKeymaps } from "@/features/keymaps/hooks/use-keymaps";
import { openFocusedFile } from "@/features/keymaps/hooks/use-file-open-target";
import { keymapRegistry } from "@/features/keymaps/utils/registry";
import { registerDefaultKeymaps } from "@/features/keymaps/defaults/register-defaults";
import { useKeymapStore } from "@/features/keymaps/stores/keymaps.store";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { useGlobalSearchStore } from "../stores/global-search.store";
import * as contentSearch from "../hooks/use-content-search";
import * as excerptTokens from "../hooks/use-search-excerpt-tokens";
import GlobalSearchBuffer from "./global-search-buffer";

const firstPath = "C:/fixture/f4/first.ts";
const secondPath = "C:/fixture/f4/second.ts";
const openFile = mock(
  async (_path: string, _isDir: boolean, _line?: number, _column?: number) => "",
);
const initialFileSystem = useFileSystemStore.getState();
const initialSettings = useSettingsStore.getState().settings;
const initialKeymaps = useKeymapStore.getState();
const initialSearch = useGlobalSearchStore.getState();
let search: ReturnType<typeof contentSearch.useContentSearch>;
let restoreDom: () => void;
let previousAct: boolean | undefined;
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let root: Root;
let container: HTMLDivElement;
let observerDescriptor: PropertyDescriptor | undefined;
let intersectionObserverDescriptor: PropertyDescriptor | undefined;
const spies: Array<{ mockRestore(): void }> = [];
const observeMore = mock((_target: Element) => {});

function Navigation({ language }: { language: DisplayLanguage }) {
  useKeymaps();
  return (
    <LocaleProvider language={language}>
      <GlobalSearchBuffer />
    </LocaleProvider>
  );
}

async function render(language: DisplayLanguage = "en-US") {
  await act(async () => root.render(<Navigation language={language} />));
}

async function press(target: HTMLElement, key: string, ctrlKey = false, altKey = false) {
  const event = new KeyboardEvent("keydown", {
    key,
    ctrlKey,
    altKey,
    bubbles: true,
    cancelable: true,
  });
  await act(async () => {
    target.focus();
    target.dispatchEvent(event);
  });
  return event;
}

const queryInput = () =>
  container.querySelector<HTMLInputElement>('input[aria-label="Search in files..."]')!;

beforeEach(async () => {
  restoreDom = installHappyDom();
  spies.push(spyOn(globalThis, "requestAnimationFrame").mockReturnValue(0));
  previousAct = actGlobal.IS_REACT_ACT_ENVIRONMENT;
  actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  observeMore.mockClear();
  observerDescriptor = Object.getOwnPropertyDescriptor(globalThis, "ResizeObserver");
  intersectionObserverDescriptor = Object.getOwnPropertyDescriptor(
    globalThis,
    "IntersectionObserver",
  );
  Object.defineProperty(globalThis, "IntersectionObserver", {
    configurable: true,
    value: class {
      observe(target: Element) { observeMore(target); }
      disconnect() {}
    },
  });
  Object.defineProperty(globalThis, "ResizeObserver", {
    configurable: true,
    value: class {
      observe() {}
      disconnect() {}
    },
  });
  openFile.mockClear();
  useFileSystemStore.setState({ handleFileSelect: openFile });
  useSettingsStore.setState({
    settings: {
      ...initialSettings,
      vimMode: false,
      nativeMenuBar: false,
      keybindingPreset: "none",
      showFileIconsInFileTree: false,
    },
  });
  useKeymapStore.setState({ keybindings: [], contexts: {} });
  useGlobalSearchStore.setState({ replaceVisible: true, scopePaths: [] });
  search = {
    query: "match",
    debouncedQuery: "match",
    searchKey: "f4-match",
    availability: "ready",
    rootFolderPath: "C:/fixture/f4",
    isSearching: false,
    isSearchPending: false,
    isLoadingMore: false,
    isIndexing: false,
    hasMoreResults: false,
    searchedFiles: 2,
    searchableFiles: 2,
    indexedFiles: 2,
    scannedFiles: 2,
    error: null,
    searchWarning: null,
    includeQuery: "",
    excludeQuery: "",
    searchOptions: { caseSensitive: false, wholeWord: false, useRegex: false },
    setQuery() {},
    setSearchOption() {},
    setIncludeQuery() {},
    setExcludeQuery() {},
    refreshSearch: async () => {},
    loadMoreResults: async () => {},
    results: [
      {
        file_path: firstPath,
        total_matches: 2,
        matches: [
          { line_number: 8, line_content: "match", column_start: 0, column_end: 5 },
          { line_number: 27, line_content: "    match", column_start: 4, column_end: 9 },
        ],
      },
      {
        file_path: secondPath,
        total_matches: 1,
        matches: [{ line_number: 13, line_content: "  match", column_start: 2, column_end: 7 }],
      },
    ],
  };
  spies.push(spyOn(contentSearch, "useContentSearch").mockImplementation(() => search));
  // Tokenization is independent of file navigation; prevent background syntax timers.
  spies.push(spyOn(excerptTokens, "useSearchExcerptTokens").mockReturnValue([]));
  keymapRegistry.registerCommand({
    id: "file.openSelected",
    title: "Open Selected File",
    execute: openFocusedFile,
  });
  registerDefaultKeymaps();
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  await render();
});

afterEach(async () => {
  await act(async () => root.unmount());
  container.remove();
  keymapRegistry.clear();
  for (const spy of spies.splice(0)) spy.mockRestore();
  useFileSystemStore.setState({ handleFileSelect: initialFileSystem.handleFileSelect });
  useSettingsStore.setState({ settings: initialSettings });
  useKeymapStore.setState(initialKeymaps);
  useGlobalSearchStore.setState(initialSearch);
  if (observerDescriptor) Object.defineProperty(globalThis, "ResizeObserver", observerDescriptor);
  else Reflect.deleteProperty(globalThis, "ResizeObserver");
  if (intersectionObserverDescriptor)
    Object.defineProperty(globalThis, "IntersectionObserver", intersectionObserverDescriptor);
  else Reflect.deleteProperty(globalThis, "IntersectionObserver");
  restoreDom();
  if (previousAct === undefined) delete actGlobal.IS_REACT_ACT_ENVIRONMENT;
  else actGlobal.IS_REACT_ACT_ENVIRONMENT = previousAct;
});

test("partial search failures stay visible beside results and pause automatic loading until retry", async () => {
  const retry = mock(async () => {});
  const priorObservations = observeMore.mock.calls.length;
  search = {
    ...search,
    error: { kind: "indexing", code: "readFailed" },
    hasMoreResults: true,
    loadMoreResults: retry,
  };
  await render("zh-CN");
  const firstRow = () => container.querySelector(`[data-file-navigator-key="${firstPath}"]`);
  expect(firstRow()).not.toBeNull();
  expect(container.querySelector('[role="alert"]')?.textContent).toContain(
    createTranslator("zh-CN")("indexing.readFailed"),
  );
  expect(observeMore).toHaveBeenCalledTimes(priorObservations);
  await render("en-US");
  const alert = container.querySelector<HTMLElement>('[role="alert"]')!;
  expect(alert.textContent).toContain(createTranslator("en-US")("indexing.readFailed"));
  expect(retry).not.toHaveBeenCalled();
  await act(async () => alert.querySelector<HTMLButtonElement>("button")!.click());
  expect(retry).toHaveBeenCalledTimes(1);
  expect(firstRow()).not.toBeNull();
});

test("F4 from the search query opens the keyboard-selected match with one-based location", async () => {
  const input = queryInput();
  expect(input).not.toBeNull();
  await press(input, "ArrowDown");
  expect((await press(input, "F4")).defaultPrevented).toBe(true);
  expect(openFile).toHaveBeenCalledTimes(1);
  expect(openFile).toHaveBeenLastCalledWith(firstPath, false, 27, 5);
  await press(input, "Enter");
  expect(openFile).toHaveBeenLastCalledWith(firstPath, false, 27, 5);
});

test("F4 uses the focused excerpt or file row instead of a different selected result", async () => {
  const excerpt = container.querySelector<HTMLElement>('[data-excerpt-index="1"]')!;
  await press(excerpt, "F4");
  expect(openFile).toHaveBeenLastCalledWith(secondPath, false, 13, 3);
  const fileRow = container.querySelector<HTMLElement>(
    `[data-file-navigator-key="${secondPath}"]`,
  )!;
  expect(fileRow).not.toBeNull();
  await press(fileRow, "F4");
  expect(openFile).toHaveBeenCalledTimes(2);
  expect(openFile).toHaveBeenLastCalledWith(secondPath, false, 13, 3);
});

test("F4 opens a result file before its excerpt is rendered", async () => {
  const matches = Array.from({ length: 40 }, (_, index) => ({
    line_number: index + 1,
    line_content: "match",
    column_start: 0,
    column_end: 5,
  }));
  search = {
    ...search,
    results: [{ ...search.results[0], matches, total_matches: 40 }, search.results[1]],
  };
  await render();
  expect(container.querySelector('[data-excerpt-index="1"]')).toBeNull();
  const fileRow = container.querySelector<HTMLElement>(
    `[data-file-navigator-key="${secondPath}"]`,
  )!;
  expect((await press(fileRow, "F4")).defaultPrevented).toBe(true);
  expect(openFile).toHaveBeenLastCalledWith(secondPath, false, 13, 3);
});

test("F4 on a focused code line overrides the earlier selected match in that excerpt", async () => {
  const line = container.querySelector<HTMLButtonElement>('button[aria-label="Open line 27"]')!;
  expect(line).not.toBeNull();
  expect((await press(line, "F4")).defaultPrevented).toBe(true);
  expect(openFile).toHaveBeenLastCalledWith(firstPath, false, 27, 5);
  // Header/section focus continues to use the independently selected match.
  await press(container.querySelector<HTMLElement>('[data-excerpt-index="0"]')!, "F4");
  expect(openFile).toHaveBeenLastCalledWith(firstPath, false, 8, 1);
  search = { ...search, isSearchPending: true };
  await render();
  expect((await press(line, "F4")).defaultPrevented).toBe(false);
  expect(openFile).toHaveBeenCalledTimes(2);
});

test("custom shortcut replaces F4 and remains scoped to a valid file target", async () => {
  await act(async () =>
    useKeymapStore
      .getState()
      .actions.addKeybinding({ key: "ctrl+alt+o", command: "file.openSelected", source: "user" }),
  );
  expect((await press(queryInput(), "F4")).defaultPrevented).toBe(false);
  expect(openFile).not.toHaveBeenCalled();
  expect((await press(queryInput(), "o", true, true)).defaultPrevented).toBe(true);
  expect(openFile).toHaveBeenCalledTimes(1);
  const replacement = container.querySelector<HTMLInputElement>(
    'input[placeholder="Replace with..."]',
  )!;
  expect(replacement).not.toBeNull();
  expect((await press(replacement, "o", true, true)).defaultPrevented).toBe(false);
  expect(openFile).toHaveBeenCalledTimes(1);
  for (const className of ["monaco-editor", "terminal-container"]) {
    const region = document.createElement("div");
    region.className = className;
    const input = document.createElement("textarea");
    region.append(input);
    container.append(region);
    expect((await press(input, "o", true, true)).defaultPrevented).toBe(false);
    region.remove();
  }
  expect(openFile).toHaveBeenCalledTimes(1);
  await act(async () =>
    useKeymapStore.getState().actions.updateKeybinding("file.openSelected", { enabled: false }),
  );
  expect((await press(queryInput(), "o", true, true)).defaultPrevented).toBe(false);
  expect(openFile).toHaveBeenCalledTimes(1);
});

test("F4 in search still works with editor Vim mode enabled", async () => {
  await act(async () =>
    useSettingsStore.setState({
      settings: { ...useSettingsStore.getState().settings, vimMode: true },
    }),
  );
  expect((await press(queryInput(), "F4")).defaultPrevented).toBe(true);
  expect(openFile).toHaveBeenLastCalledWith(firstPath, false, 8, 1);
});

test("pending and empty search targets and unrelated inputs do not open stale files", async () => {
  const filter = container.querySelector<HTMLInputElement>('input[aria-label="Files to include"]')!;
  expect(filter).not.toBeNull();
  expect((await press(filter, "F4")).defaultPrevented).toBe(false);
  search = { ...search, isSearchPending: true };
  await render();
  expect((await press(queryInput(), "F4")).defaultPrevented).toBe(false);
  search = { ...search, isSearchPending: false, results: [] };
  await render();
  expect((await press(queryInput(), "F4")).defaultPrevented).toBe(false);
  expect(openFile).not.toHaveBeenCalled();
});

test("two-step file shortcut completes and resets after success or an unmatched key", async () => {
  await act(async () =>
    useKeymapStore.getState().actions.addKeybinding({
      key: "ctrl+alt+k ctrl+alt+o",
      command: "file.openSelected",
      source: "user",
    }),
  );
  const input = queryInput();
  expect((await press(input, "k", true, true)).defaultPrevented).toBe(true);
  expect(openFile).not.toHaveBeenCalled();
  expect((await press(input, "o", true, true)).defaultPrevented).toBe(true);
  expect(openFile).toHaveBeenLastCalledWith(firstPath, false, 8, 1);
  // Completion releases the chord, so a second full sequence works immediately.
  await press(input, "k", true, true);
  await press(input, "o", true, true);
  expect(openFile).toHaveBeenCalledTimes(2);
  await press(input, "k", true, true);
  expect((await press(input, "x", true, true)).defaultPrevented).toBe(false);
  expect((await press(input, "o", true, true)).defaultPrevented).toBe(false);
  await press(input, "k", true, true);
  await press(input, "o", true, true);
  expect(openFile).toHaveBeenCalledTimes(3);
});

test("a pending file chord cannot execute from the replacement input", async () => {
  await act(async () =>
    useKeymapStore.getState().actions.addKeybinding({
      key: "ctrl+alt+k ctrl+alt+o",
      command: "file.openSelected",
      source: "user",
    }),
  );
  const input = queryInput();
  const replacement = container.querySelector<HTMLInputElement>(
    'input[placeholder="Replace with..."]',
  )!;
  await press(input, "k", true, true);
  expect((await press(replacement, "o", true, true)).defaultPrevented).toBe(false);
  expect((await press(input, "o", true, true)).defaultPrevented).toBe(false);
  expect(openFile).not.toHaveBeenCalled();
});

test("file chord timeout survives rerender and its timer is released on unmount", async () => {
  await act(async () =>
    useKeymapStore.getState().actions.addKeybinding({
      key: "ctrl+alt+k ctrl+alt+o",
      command: "file.openSelected",
      source: "user",
    }),
  );
  const timers = new Map<ReturnType<typeof setTimeout>, () => void>();
  const setTimer = globalThis.setTimeout;
  const clearTimer = globalThis.clearTimeout;
  spies.push(
    spyOn(globalThis, "setTimeout").mockImplementation(((
      callback: (...args: unknown[]) => void,
      delay?: number,
      ...args: unknown[]
    ) => {
      if (delay !== 1000) return setTimer(callback, delay, ...args);
      const timer = {} as ReturnType<typeof setTimeout>;
      timers.set(timer, () => callback(...args));
      return timer;
    }) as typeof setTimeout),
  );
  spies.push(
    spyOn(globalThis, "clearTimeout").mockImplementation((timer) => {
      if (timer && timers.delete(timer as ReturnType<typeof setTimeout>)) return;
      clearTimer(timer as number | undefined);
    }),
  );
  const input = queryInput();
  await press(input, "k", true, true);
  // React has replaced the listener after recording the first key; its deadline must remain.
  expect(timers.size).toBe(1);
  await act(async () => {
    const [timer, callback] = [...timers.entries()][0]!;
    timers.delete(timer);
    callback();
  });
  expect((await press(input, "o", true, true)).defaultPrevented).toBe(false);
  expect(openFile).not.toHaveBeenCalled();
  await press(input, "k", true, true);
  await press(input, "o", true, true);
  expect(openFile).toHaveBeenCalledTimes(1);
  expect(timers.size).toBe(0);
  await press(input, "k", true, true);
  expect(timers.size).toBe(1);
  await act(async () => root.render(null));
  expect(timers.size).toBe(0);
});
