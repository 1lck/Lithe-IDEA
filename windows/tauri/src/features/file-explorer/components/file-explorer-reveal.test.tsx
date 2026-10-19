import { afterEach, beforeEach, expect, test } from "bun:test";
import { enableMapSet } from "immer";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { createPaneContent } from "@/features/editor/stores/buffer-content-factory";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { useFileTreeStore } from "@/features/file-explorer/stores/file-explorer-tree.store";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import type { FileEntry } from "@/features/file-system/types/app.types";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { workspaceRuntimeRegistry as registry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import { FileExplorerTree } from "./file-explorer-tree";

const rootPath = "C:/workspace/reveal";
const directoryPath = `${rootPath}/src`;
const targetPath = `${directoryPath}/z-current.ts`;
const children: FileEntry[] = [
  ...Array.from({ length: 120 }, (_, index) => ({
    name: `file-${String(index).padStart(3, "0")}.ts`,
    path: `${directoryPath}/file-${String(index).padStart(3, "0")}.ts`,
    isDir: false,
  })),
  { name: "z-current.ts", path: targetPath, isDir: false },
];
const filesWithChildren = (entries: FileEntry[]): FileEntry[] => [
  {
    name: "reveal",
    path: rootPath,
    isDir: true,
    children: [{ name: "src", path: directoryPath, isDir: true, children: entries }],
  },
];

let restoreDom: () => void;
let container: HTMLDivElement;
let root: Root;
let settings: ReturnType<typeof useSettingsStore.getState>["settings"];
let previousObserver: PropertyDescriptor | undefined;
let previousHeight: PropertyDescriptor | undefined;
let previousAct: boolean | undefined;
let pendingLoads: Array<() => void>;
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };

function ProjectTree() {
  const files = useFileSystemStore((state) => state.files);
  return (
    <LocaleProvider language="en-US">
      <FileExplorerTree
        files={files}
        activePath={targetPath}
        rootFolderPath={rootPath}
        onFileSelect={() => {}}
        onCreateNewFileInDirectory={() => {}}
      />
    </LocaleProvider>
  );
}

const viewport = () => container.querySelector<HTMLElement>('[role="tree"]')!;
const targetRow = () => container.querySelector<HTMLElement>(`[data-path="${targetPath}"]`);
const locate = async () => {
  await act(async () => {
    container.querySelector<HTMLButtonElement>('[aria-label="Select Opened File"]')!.click();
  });
};

// Native directory reads are released explicitly; teardown also releases failed tests.
function deferExpansion() {
  let release!: () => void;
  const ready = new Promise<void>((resolve) => {
    release = resolve;
  });
  pendingLoads.push(release);
  return { ready, release };
}

beforeEach(() => {
  enableMapSet();
  registry.resetForTests();
  registry.activateWorkspace({ id: "reveal-test", name: "reveal-test" }, "ready");
  restoreDom = installHappyDom();
  previousAct = actGlobal.IS_REACT_ACT_ENVIRONMENT;
  actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  pendingLoads = [];
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
      return this.getAttribute("role") === "tree" ? 200 : 0;
    },
  });
  settings = useSettingsStore.getState().settings;
  useSettingsStore.setState({
    settings: {
      ...settings,
      autoRevealActiveFileInFileTree: false,
      compactFoldersInFileTree: false,
      showFileIconsInFileTree: false,
    },
  });
  useFileSystemStore.setState({ rootFolderPath: rootPath, files: filesWithChildren(children) });
  useBufferStore.setState({
    activeBufferId: "current",
    buffers: [
      createPaneContent("current", {
        type: "editor",
        path: targetPath,
        name: "z-current.ts",
        content: "",
      }),
    ],
  });
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
});

afterEach(async () => {
  await act(async () => {
    root.unmount();
    for (const release of pendingLoads) release();
  });
  container.remove();
  useSettingsStore.setState({ settings });
  registry.resetForTests();
  if (previousObserver) Object.defineProperty(globalThis, "ResizeObserver", previousObserver);
  else Reflect.deleteProperty(globalThis, "ResizeObserver");
  if (previousHeight) Object.defineProperty(HTMLElement.prototype, "clientHeight", previousHeight);
  else Reflect.deleteProperty(HTMLElement.prototype, "clientHeight");
  restoreDom();
  if (previousAct === undefined) delete actGlobal.IS_REACT_ACT_ENVIRONMENT;
  else actGlobal.IS_REACT_ACT_ENVIRONMENT = previousAct;
});

test("locate expands collapsed ancestors and renders the offscreen current file with auto reveal off", async () => {
  await act(async () => root.render(<ProjectTree />));
  expect(targetRow()).toBeNull();
  expect(viewport().scrollTop).toBe(0);

  await locate();

  expect(useFileTreeStore.getState().expandedPaths.has(directoryPath)).toBe(true);
  expect(viewport().scrollTop).toBeGreaterThan(0);
  expect(targetRow()).not.toBeNull();
  expect(container.querySelectorAll('[role="treeitem"]').length).toBeLessThan(40);
});

test("locate scrolls again when the active file has not changed", async () => {
  await act(async () => root.render(<ProjectTree />));
  await locate();
  const locatedScrollTop = viewport().scrollTop;
  viewport().scrollTop = 0;

  await locate();

  expect(locatedScrollTop).toBeGreaterThan(0);
  expect(viewport().scrollTop).toBe(locatedScrollTop);
  expect(targetRow()).not.toBeNull();
});

test("locate waits for lazy directory loading before scrolling", async () => {
  const load = deferExpansion();
  useFileSystemStore.setState({
    files: filesWithChildren([]),
    revealPathInTree: async () => {
      await load.ready;
      useFileSystemStore.setState({ files: filesWithChildren(children) });
      useFileTreeStore.getState().actions.setExpandedPaths(new Set([rootPath, directoryPath]));
    },
  });
  await act(async () => root.render(<ProjectTree />));
  await locate();
  expect(viewport().scrollTop).toBe(0);
  expect(targetRow()).toBeNull();

  await act(async () => load.release());

  expect(viewport().scrollTop).toBeGreaterThan(0);
  expect(targetRow()).not.toBeNull();
});

test("a superseded locate completion does not scroll back after the latest request", async () => {
  const oldLoad = deferExpansion();
  const newLoad = deferExpansion();
  let calls = 0;
  useFileSystemStore.setState({
    revealPathInTree: async () => {
      const load = calls++ === 0 ? oldLoad : newLoad;
      await load.ready;
      useFileTreeStore.getState().actions.setExpandedPaths(new Set([rootPath, directoryPath]));
    },
  });
  await act(async () => root.render(<ProjectTree />));
  await locate();
  await locate();
  await act(async () => newLoad.release());
  expect(viewport().scrollTop).toBeGreaterThan(0);
  viewport().scrollTop = 0;

  await act(async () => oldLoad.release());

  expect(viewport().scrollTop).toBe(0);
});

test("automatic reveal still scrolls the active file into the virtual viewport", async () => {
  useSettingsStore.setState({
    settings: { ...useSettingsStore.getState().settings, autoRevealActiveFileInFileTree: true },
  });
  await act(async () => root.render(<ProjectTree />));

  expect(viewport().scrollTop).toBeGreaterThan(0);
  expect(targetRow()).not.toBeNull();
});
