import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import { enableMapSet } from "immer";
import { mockIPC, clearMocks } from "@tauri-apps/api/mocks";
import { act, forwardRef, type ComponentProps } from "react";
import { createRoot, type Root } from "react-dom/client";
import * as debounce from "use-debounce";
import * as searchApi from "@/features/file-search/lib/file-search-api";
import { createPaneContent } from "@/features/editor/stores/buffer-content-factory";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { useSidebarStore } from "@/features/layout/stores/sidebar.store";
import { useFileClipboardStore } from "../stores/file-explorer-clipboard.store";
import { useFileTreeStore } from "../stores/file-explorer-tree.store";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import type { FileEntry } from "@/features/file-system/types/app.types";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { workspaceRuntimeRegistry as registry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import { FileExplorerPane } from "./file-explorer-pane";
import * as sidebar from "@/ui/sidebar";

const originalSidebar = { ...sidebar };
// The tree owns selection; this controlled input isolates the popover's presentation lifecycle.
const SearchInput = forwardRef<
  HTMLInputElement,
  ComponentProps<typeof sidebar.SidebarSearchPopover>
>(function SearchInput({ open, value, onChange, onKeyDown, "aria-label": label }, ref) {
  return open ? (
    <input
      ref={ref}
      aria-label={label}
      value={value}
      onInput={(event) => onChange(event.currentTarget.value)}
      onKeyDown={onKeyDown}
    />
  ) : null;
});

const workspace = "C:/fixture/selection";
const directory = `${workspace}/src`;
const child = `${directory}/a.ts`;
const readme = `${workspace}/README.md`;
const matches = ["match-1.ts", "match-2.ts"].map((name) => ({
  name,
  path: `${workspace}/${name}`,
  isDir: false,
}));
const files: FileEntry[] = [
  {
    name: "selection",
    path: workspace,
    isDir: true,
    children: [
      {
        name: "src",
        path: directory,
        isDir: true,
        children: [{ name: "a.ts", path: child, isDir: false }],
      },
      { name: "README.md", path: readme, isDir: false },
      ...matches,
    ],
  },
];
let restoreDom: () => void;
let root: Root;
let container: HTMLDivElement;
let settings: ReturnType<typeof useSettingsStore.getState>["settings"];
let previousHeight: PropertyDescriptor | undefined;
let previousObserver: PropertyDescriptor | undefined;
let previousAct: boolean | undefined;
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
const spies: Array<{ mockRestore(): void }> = [];
let deleted: string[];

function setEditorPath(path?: string) {
  useBufferStore.setState({
    activeBufferId: path ?? null,
    buffers: path
      ? [createPaneContent(path, { type: "editor", path, name: path.split("/").pop()!, content: "" })]
      : [],
  });
}

async function renderTree(editorPath?: string) {
  await act(async () => {
    setEditorPath(editorPath);
    root.render(
      <LocaleProvider language="en-US">
        <FileExplorerPane />
      </LocaleProvider>,
    );
  });
}

function settledDebounce<T>(value: T): ReturnType<typeof debounce.useDebounce<T>> {
  return [value, Object.assign(() => {}, { cancel() {}, flush() {}, isPending: () => false })];
}

beforeEach(async () => {
  enableMapSet();
  registry.resetForTests();
  registry.activateWorkspace({ id: "selection-test", name: "Selection" }, "ready");
  restoreDom = installHappyDom();
  mock.module("@/ui/sidebar", () => ({ ...originalSidebar, SidebarSearchPopover: SearchInput }));
  mockIPC((command) => {
    if (command === "clipboard_set") return;
    throw new Error(`Unexpected native call: ${command}`);
  });
  previousAct = actGlobal.IS_REACT_ACT_ENVIRONMENT;
  actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  previousObserver = Object.getOwnPropertyDescriptor(globalThis, "ResizeObserver");
  Object.defineProperty(globalThis, "ResizeObserver", {
    configurable: true,
    value: class {
      observe() {}
      disconnect() {}
    },
  });
  previousHeight = Object.getOwnPropertyDescriptor(HTMLElement.prototype, "clientHeight");
  Object.defineProperty(HTMLElement.prototype, "clientHeight", {
    configurable: true,
    get() {
      return this.getAttribute("role") === "tree" ? 400 : 0;
    },
  });
  // Search settlement is explicit; these regressions exercise selection, not debounce timing.
  spies.push(spyOn(debounce, "useDebounce").mockImplementation(settledDebounce));
  spies.push(
    spyOn(searchApi, "fffSearchFiles").mockResolvedValue(
      matches.map((file) => ({
        ...file,
        relative_path: file.name,
        score: 1,
      })),
    ),
  );
  settings = useSettingsStore.getState().settings;
  useSettingsStore.setState({
    settings: {
      ...settings,
      autoRevealActiveFileInFileTree: false,
      compactFoldersInFileTree: false,
      showFileIconsInFileTree: false,
      confirmBeforeFileDelete: false,
    },
  });
  // Keep the real pane/store wiring; replace only disk/editor-opening side effects.
  useFileSystemStore.setState({
    rootFolderPath: workspace,
    files,
    handleFileSelect: async (path) => {
      setEditorPath(path);
      return path;
    },
    handleDeletePath: async (path) => {
      deleted.push(path);
    },
  });
  useFileTreeStore.getState().actions.setExpandedPaths(new Set([workspace, directory]));
  useFileClipboardStore.setState({ clipboard: null });
  deleted = [];
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  await renderTree();
});

afterEach(async () => {
  await act(async () => root.unmount());
  container.remove();
  for (const spy of spies.splice(0)) spy.mockRestore();
  mock.module("@/ui/sidebar", () => originalSidebar);
  useFileClipboardStore.setState({ clipboard: null });
  useSettingsStore.setState({ settings });
  registry.resetForTests();
  clearMocks();
  if (previousObserver) Object.defineProperty(globalThis, "ResizeObserver", previousObserver);
  else Reflect.deleteProperty(globalThis, "ResizeObserver");
  if (previousHeight) Object.defineProperty(HTMLElement.prototype, "clientHeight", previousHeight);
  else Reflect.deleteProperty(HTMLElement.prototype, "clientHeight");
  restoreDom();
  if (previousAct === undefined) delete actGlobal.IS_REACT_ACT_ENVIRONMENT;
  else actGlobal.IS_REACT_ACT_ENVIRONMENT = previousAct;
});

const row = (path: string) => container.querySelector<HTMLElement>(`[data-file-path="${path}"]`)!;
async function click(path: string, additive = false, range = false) {
  await act(async () =>
    row(path).dispatchEvent(
      new window.MouseEvent("click", {
        bubbles: true,
        ctrlKey: additive,
        shiftKey: range,
      }),
    ),
  );
}
async function key(target: HTMLElement, value: string, ctrlKey = false) {
  await act(async () =>
    target.dispatchEvent(
      new KeyboardEvent("keydown", {
        bubbles: true,
        key: value,
        ctrlKey,
      }),
    ),
  );
}
async function menuAction(label: string) {
  await act(async () =>
    row(child).dispatchEvent(new window.MouseEvent("contextmenu", { bubbles: true })),
  );
  const item = [...document.querySelectorAll<HTMLElement>('[role="menuitem"]')].find(
    (element) => element.textContent?.trim() === label,
  );
  expect(item).toBeDefined();
  await act(async () => item!.click());
}

test("search results and Enter navigation replace the previous clipboard selection", async () => {
  await click(child);
  const tree = container.querySelector<HTMLElement>('[role="tree"]')!;
  async function search() {
    await key(tree, "f", true);
    const input = document.querySelector<HTMLInputElement>('input[aria-label="Search files"]')!;
    expect(input === null).toBe(false);
    await act(async () => {
      input.focus();
      Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value")!.set!.call(
        input,
        "match",
      );
      input.dispatchEvent(new Event("input", { bubbles: true }));
    });
    expect(row(readme) === null).toBe(true);
    return input;
  }
  let input = await search();
  await key(input, "Escape");
  await key(tree, "c", true);
  expect(useFileClipboardStore.getState().clipboard?.entries.map((entry) => entry.path)).toEqual([
    matches[0].path,
  ]);
  input = await search();
  await key(input, "Enter");
  await key(input, "Escape");
  await key(tree, "x", true);
  expect(useFileClipboardStore.getState().clipboard?.entries.map((entry) => entry.path)).toEqual([
    matches[1].path,
  ]);
});

test("right-clicking a selected descendant keeps the whole selection for copy and delete", async () => {
  await click(directory);
  await click(child, true);
  await click(readme, true);
  await menuAction("Copy");
  expect(useFileClipboardStore.getState().clipboard?.entries.map((entry) => entry.path)).toEqual([
    directory,
    readme,
  ]);
  await menuAction("Delete");
  expect(deleted).toEqual([directory, readme]);
});

test("a single selection follows editor tabs for highlight, copy and cut", async () => {
  await renderTree(child);
  await click(child);
  await renderTree(readme);
  expect(row(child).getAttribute("aria-selected")).toBe("false");
  expect(row(readme).getAttribute("aria-selected")).toBe("true");
  const tree = container.querySelector<HTMLElement>('[role="tree"]')!;
  await key(tree, "c", true);
  expect(useFileClipboardStore.getState().clipboard?.entries.map((entry) => entry.path)).toEqual([
    readme,
  ]);
  await key(tree, "x", true);
  expect(useFileClipboardStore.getState().clipboard?.entries.map((entry) => entry.path)).toEqual([
    readme,
  ]);
});

test("editor tab changes preserve an explicit group and its clipboard targets", async () => {
  await renderTree(child);
  await click(child);
  await click(readme, true);
  await renderTree(matches[0].path);
  expect(row(child).getAttribute("aria-selected")).toBe("true");
  expect(row(readme).getAttribute("aria-selected")).toBe("true");
  expect(row(matches[0].path).getAttribute("aria-selected")).toBe("false");
  await key(container.querySelector<HTMLElement>('[role="tree"]')!, "c", true);
  expect(useFileClipboardStore.getState().clipboard?.entries.map((entry) => entry.path)).toEqual([
    child,
    readme,
  ]);
});

test("an unchanged editor path does not overwrite a newly selected directory", async () => {
  await renderTree(readme);
  await click(directory);
  // The sync effect restores the sidebar path to README without switching editors.
  expect(useSidebarStore.getState().activePath).toBe(readme);
  await renderTree(readme);
  expect(row(directory).getAttribute("aria-selected")).toBe("true");
  expect(row(readme).getAttribute("aria-selected")).toBe("false");
  const tree = container.querySelector<HTMLElement>('[role="tree"]')!;
  await key(tree, "c", true);
  expect(useFileClipboardStore.getState().clipboard?.entries.map((entry) => entry.path)).toEqual([
    directory,
  ]);
  await key(tree, "x", true);
  expect(useFileClipboardStore.getState().clipboard?.entries.map((entry) => entry.path)).toEqual([
    directory,
  ]);
  // The directory remains the keyboard focus and range anchor after the roundtrip.
  await key(tree, "ArrowDown");
  expect(row(child).getAttribute("aria-selected")).toBe("true");
  await click(directory);
  await click(readme, false, true);
  expect(row(directory).getAttribute("aria-selected")).toBe("true");
  expect(row(child).getAttribute("aria-selected")).toBe("true");
  expect(row(readme).getAttribute("aria-selected")).toBe("true");
  await click(directory);
  await renderTree(matches[0].path);
  expect(row(directory).getAttribute("aria-selected")).toBe("false");
  expect(row(matches[0].path).getAttribute("aria-selected")).toBe("true");
});

test("following an editor tab also moves the anchor for the next range selection", async () => {
  await renderTree(child);
  await click(child);
  await renderTree(readme);
  await click(matches[1].path, false, true);
  expect(row(readme).getAttribute("aria-selected")).toBe("true");
  expect(row(matches[1].path).getAttribute("aria-selected")).toBe("true");
  expect(row(child).getAttribute("aria-selected")).toBe("false");
});
