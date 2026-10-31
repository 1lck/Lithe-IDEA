import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { useFileExplorerContextMenu } from "../hooks/use-file-explorer-context-menu";
import { afterEach, beforeEach, expect, test } from "bun:test";
import { installHappyDom } from "@/test-utils/happy-dom";
import { IndexingSettingsError, indexingSettingsStorageKey, readIndexingSettings, writeIndexingSettings } from "./workspace-indexing";
import { directoryMarkRoot, markWorkspaceDirectory, migrateWorkspaceDirectoryMarks, migrateDirectoryMarks, readDirectoryMarks } from "./directory-marks";

let restore: () => void;
const storageKey = "lithe.workspace-directory-marks.c:/workspace";
beforeEach(() => {
  restore = installHappyDom();
});
afterEach(() => restore());

test("cancelling exclusion follows Windows path identity after a case-only rename", () => {
  markWorkspaceDirectory(["C:/workspace"], "C:/workspace/src", "sources");
  markWorkspaceDirectory(["C:/workspace"], "C:/workspace/src", "excluded");
  markWorkspaceDirectory(["C:/workspace"], "C:/workspace/SRC", "plain", true);
  expect(readDirectoryMarks("C:/workspace")).toEqual({ SRC: "sources" });
  expect(readIndexingSettings("C:/workspace").previousRoles).toEqual({});
  expect(readIndexingSettings("C:/workspace").includedDirectories).toEqual(["SRC"]);
  markWorkspaceDirectory(["C:/workspace"], "C:/workspace/src", "excluded");
  expect(readDirectoryMarks("C:/workspace")).toEqual({ src: "excluded" });
  expect(readIndexingSettings("C:/workspace").includedDirectories).toEqual([]);
  markWorkspaceDirectory(["C:/workspace"], "C:/workspace/SRC/child", "plain", true);
  expect(readIndexingSettings("C:/workspace").includedDirectories).toEqual([]);
});

test("directory mark read failures use stable classes and preserve the original data", () => {
  for (const raw of ["broken", "null", "{}", '{"version":1,"marks":[]}']) {
    window.localStorage.setItem(storageKey, raw);
    try { readDirectoryMarks("C:/workspace"); throw new Error("Expected invalid data to fail"); }
    catch (error) {
      expect(error).toBeInstanceOf(IndexingSettingsError);
      expect((error as IndexingSettingsError).code).toBe("invalidSettings");
    }
    expect(window.localStorage.getItem(storageKey)).toBe(raw);
  }
  const failing = { getItem: () => { throw new Error("storage is unavailable"); } } as unknown as Storage;
  expect(() => readDirectoryMarks("C:/workspace", failing)).toThrow(IndexingSettingsError);
});

test("directory marks migrate a renamed subtree and remove a deleted subtree", () => {
  window.localStorage.setItem(
    storageKey,
    JSON.stringify({
      version: 1,
      marks: { src: "sources", "src/a": "package", assets: "resources" },
    }),
  );
  migrateDirectoryMarks("C:/workspace", "c:\\WORKSPACE\\SRC", "C:/workspace/code");
  expect(readDirectoryMarks("c:\\WORKSPACE\\")).toEqual({
    code: "sources",
    "code/a": "package",
    assets: "resources",
  });
  migrateDirectoryMarks("C:/workspace", "C:/workspace/code");
  expect(readDirectoryMarks("C:/workspace")).toEqual({ assets: "resources" });
  expect(readDirectoryMarks("C:/other")).toEqual({});
});

test.each([
  "wsl://Ubuntu/project",
  "remote://host/project",
  "/project",
  "//wsl.localhost/Ubuntu/project",
  "//wsl$/Ubuntu/project",
])("directory marks preserve case-sensitive paths and workspace storage: %s", (root) => {
  const storageKey = `lithe.workspace-directory-marks.${root}`;
  const otherRoot = root.replace(/project$/, "Project");
  window.localStorage.setItem(
    storageKey,
    JSON.stringify({
      version: 1,
      marks: { src: "sources", Src: "resources", "Src/a": "package" },
    }),
  );
  const otherRaw = JSON.stringify({ version: 1, marks: { src: "excluded" } });
  window.localStorage.setItem(`lithe.workspace-directory-marks.${otherRoot}`, otherRaw);

  migrateDirectoryMarks(root, `${root}/src`, `${root}/new`);

  expect(readDirectoryMarks(root)).toEqual({
    new: "sources",
    Src: "resources",
    "Src/a": "package",
  });
  migrateDirectoryMarks(root, `${root}/Src`);
  expect(readDirectoryMarks(root)).toEqual({ new: "sources" });
  expect(readDirectoryMarks(otherRoot)).toEqual({ src: "excluded" });
  expect(window.localStorage.getItem(`lithe.workspace-directory-marks.${otherRoot}`)).toBe(
    otherRaw,
  );
});

test("directory marks keep native Windows and UNC paths case-insensitive", () => {
  const root = "//server/share/workspace";
  window.localStorage.setItem(
    "lithe.workspace-directory-marks.//server/share/workspace",
    JSON.stringify({ version: 1, marks: { src: "sources", "src/a": "package" } }),
  );

  migrateDirectoryMarks(root, "\\\\SERVER\\SHARE\\WORKSPACE\\SRC", "//SERVER/SHARE/WORKSPACE/New");

  expect(readDirectoryMarks(root)).toEqual({ New: "sources", "New/a": "package" });
  expect(readDirectoryMarks("\\\\?\\UNC\\SERVER\\SHARE\\WORKSPACE\\")).toEqual({
    New: "sources",
    "New/a": "package",
  });
});

test("volume-root marks keep their existing storage key", () => {
  window.localStorage.setItem(
    "lithe.workspace-directory-marks.c:",
    JSON.stringify({ version: 1, marks: { src: "sources" } }),
  );
  expect(readDirectoryMarks("C:/")).toEqual({ src: "sources" });
});

test("corrupt storage remains intact and legal dotted directory names are accepted", () => {
  window.localStorage.setItem(storageKey, "broken");
  expect(() => migrateDirectoryMarks("C:/workspace", "C:/workspace/src")).toThrow();
  expect(window.localStorage.getItem(storageKey)).toBe("broken");
  window.localStorage.setItem(
    storageKey,
    JSON.stringify({ version: 1, marks: { "version..old": "excluded" } }),
  );
  expect(readDirectoryMarks("C:/workspace")).toEqual({ "version..old": "excluded" });
  window.localStorage.setItem(
    storageKey,
    JSON.stringify({ version: 1, marks: { "../outside": "sources" } }),
  );
  expect(() => readDirectoryMarks("C:/workspace")).toThrow();
});

test("Git include exceptions and remembered roles follow directory moves and deletion", () => {
  writeIndexingSettings("C:/workspace", {
    gitIgnoreEnabled: false,
    includedDirectories: ["src/examples", "assets"],
    previousRoles: { "src/examples": "sources" },
  });
  migrateDirectoryMarks("C:/workspace", "C:/workspace/src", "C:/workspace/code");
  expect(readIndexingSettings("C:/workspace")).toEqual({
    gitIgnoreEnabled: false,
    includedDirectories: ["code/examples", "assets"],
    previousRoles: { "code/examples": "sources" },
  });
  migrateDirectoryMarks("C:/workspace", "C:/workspace/code");
  expect(readIndexingSettings("C:/workspace")).toEqual({
    gitIgnoreEnabled: false,
    includedDirectories: ["assets"],
    previousRoles: {},
  });
});


test("indexing preferences do not overwrite marks for a similarly named workspace", () => {
  window.localStorage.setItem("lithe.workspace-directory-marks.c:/workspace.indexing", JSON.stringify({version: 1, marks: {src: "sources"}}));
  writeIndexingSettings("C:/workspace", {gitIgnoreEnabled: true, includedDirectories: [], previousRoles: {}});
  expect(readDirectoryMarks("C:/workspace.indexing")).toEqual({src: "sources"});
});


test("added and nested roots own exclusion marks and Git include exceptions", () => {
  const roots = ["C:/main", "D:/added", "D:/added/nested"];
  writeIndexingSettings("C:/main", {gitIgnoreEnabled: false, includedDirectories: ["keep"], previousRoles: {}});
  markWorkspaceDirectory(roots, "d:\\ADDED\\build", "sources");
  markWorkspaceDirectory(roots, "d:\\ADDED\\build", "excluded");
  expect(readDirectoryMarks("D:/added")).toEqual({build: "excluded"});
  expect(readIndexingSettings("D:/added").previousRoles).toEqual({build: "sources"});
  markWorkspaceDirectory(roots, "D:/added/build", "plain", true);
  expect(readDirectoryMarks("D:/added")).toEqual({build: "sources"});
  expect(readIndexingSettings("D:/added").includedDirectories).toEqual(["build"]);
  markWorkspaceDirectory(roots, "D:/added/nested/vendor", "plain", true);
  expect(directoryMarkRoot("D:/ADDED/nested/vendor", roots)).toBe("D:/added/nested");
  expect(readIndexingSettings("D:/added/nested").includedDirectories).toEqual(["vendor"]);
  expect(readIndexingSettings("C:/main")).toEqual({gitIgnoreEnabled: false, includedDirectories: ["keep"], previousRoles: {}});
  expect(readDirectoryMarks("C:/main")).toEqual({});
  expect(() => markWorkspaceDirectory(roots, "E:/outside", "excluded")).toThrow();
});

test("normal-folder role changes do not create Git include exceptions", () => {
  const roots = ["C:/normal"];
  markWorkspaceDirectory(roots, "C:/normal/src", "sources");
  markWorkspaceDirectory(roots, "C:/normal/src", "plain");
  markWorkspaceDirectory(roots, "C:/normal/ordinary", "plain");
  expect(readIndexingSettings(roots[0]).includedDirectories).toEqual([]);
  markWorkspaceDirectory(roots, "C:/normal/src", "excluded");
  markWorkspaceDirectory(roots, "C:/normal/src", "plain", true);
  expect(readIndexingSettings(roots[0]).includedDirectories).toEqual(["src"]);
});


test.each(["D:/added", "C:/main/nested"])("added-root marks and include exceptions follow rename and deletion: %s", (root) => {
  const roots = ["C:/main", root];
  markWorkspaceDirectory(roots, `${root}/src`, "sources");
  markWorkspaceDirectory(roots, `${root}/src`, "excluded");
  markWorkspaceDirectory(roots, `${root}/src/examples`, "plain", true);
  // Include exceptions cannot override a manually excluded ancestor.
  expect(readIndexingSettings(root).includedDirectories).toEqual([]);
  migrateWorkspaceDirectoryMarks(roots, `${root}/src`, `${root}/code`);
  expect(readDirectoryMarks(root)).toEqual({code: "excluded"});
  expect(readIndexingSettings(root).previousRoles).toEqual({code: "sources"});
  markWorkspaceDirectory(roots, `${root}/code`, "plain", true);
  expect(readDirectoryMarks(root)).toEqual({code: "sources"});
  expect(readIndexingSettings(root).includedDirectories).toEqual(["code"]);
  migrateWorkspaceDirectoryMarks(roots, `${root}/code`);
  expect(readDirectoryMarks(root)).toEqual({});
  expect(readIndexingSettings(root).includedDirectories).toEqual([]);
  expect(readIndexingSettings(root).previousRoles).toEqual({});
  expect(readDirectoryMarks("C:/main")).toEqual({});
});


test.each(["D:/added", "C:/main/nested"])("moving between workspace roots preserves exclusions and exceptions: %s", (root) => {
  const roots = ["C:/main", root];
  markWorkspaceDirectory(roots, `${root}/src`, "sources");
  markWorkspaceDirectory(roots, `${root}/src`, "excluded");
  markWorkspaceDirectory(roots, `${root}/examples`, "plain", true);
  migrateWorkspaceDirectoryMarks(roots, `${root}/src`, "C:/main/code");
  migrateWorkspaceDirectoryMarks(roots, `${root}/examples`, "C:/main/demos");
  expect(readDirectoryMarks(root)).toEqual({});
  expect(readDirectoryMarks("C:/main")).toEqual({code: "excluded"});
  expect(readIndexingSettings("C:/main").previousRoles).toEqual({code: "sources"});
  expect(readIndexingSettings("C:/main").includedDirectories).toEqual(["demos"]);
  expect(readIndexingSettings(root).includedDirectories).toEqual([]);
  markWorkspaceDirectory(roots, "C:/main/code", "plain", true);
  expect(readDirectoryMarks("C:/main")).toEqual({code: "sources"});
});


test("cross-root quota failure rolls back in reverse order without publishing partial state", () => {
  const roots = ["C:/main", "D:/added"];
  markWorkspaceDirectory(roots, "D:/added/long-directory-name", "sources");
  markWorkspaceDirectory(roots, "D:/added/long-directory-name", "excluded");
  const keys = roots.flatMap((root) => [
    `lithe.workspace-directory-marks.${root.toLowerCase()}`,
    `lithe.workspace-indexing.${root.toLowerCase()}`,
  ]);
  const before = keys.map((key) => window.localStorage.getItem(key));
  const storage = window.localStorage;
  const originalSet = storage.setItem.bind(storage);
  const sourceKey = keys[2];
  const targetKey = keys[0];
  let rejected = false;
  let published = 0;
  const listener = () => { published += 1; };
  window.addEventListener("lithe:directory-marks-changed", listener);
  window.addEventListener("lithe:workspace-indexing-changed", listener);
  const storageDescriptor = Object.getOwnPropertyDescriptor(window, "localStorage");
  const setItem = (key: string, value: string) => {
    if (key === keys[1] && !rejected) {
      rejected = true;
      throw new DOMException("Fixture quota", "QuotaExceededError");
    }
    // Restoring the large source before removing the new destination would
    // exceed the same quota again and leave a partially migrated workspace.
    if (rejected && key === sourceKey && value === before[2] && storage.getItem(targetKey) !== before[0]) {
      throw new DOMException("Source restored before destination", "QuotaExceededError");
    }
    originalSet(key, value);
  };
  Object.defineProperty(window, "localStorage", {configurable: true, value: {
    getItem: storage.getItem.bind(storage), removeItem: storage.removeItem.bind(storage),
    clear: storage.clear.bind(storage), key: storage.key.bind(storage),
    get length() { return storage.length; }, setItem,
  }});
  try {
    expect(() => migrateWorkspaceDirectoryMarks(roots, "D:/added/long-directory-name", "C:/main/code")).toThrow();
    expect(rejected).toBe(true);
    expect(keys.map((key) => storage.getItem(key))).toEqual(before);
    expect(published).toBe(0);
  } finally {
    if (storageDescriptor) Object.defineProperty(window, "localStorage", storageDescriptor);
    else Reflect.deleteProperty(window, "localStorage");
    window.removeEventListener("lithe:directory-marks-changed", listener);
    window.removeEventListener("lithe:workspace-indexing-changed", listener);
  }
});

test.each(["remote://host/project", "wsl://Ubuntu/project"])("unsupported roots keep old exclusion preferences and ordinary role actions: %s", async (rootPath) => {
  const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = actGlobal.IS_REACT_ACT_ENVIRONMENT;
  actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  const host = document.createElement("div");
  const renderer = createRoot(host);
  const path = `${rootPath}/src`;
  const marksKey = `lithe.workspace-directory-marks.${rootPath}`;
  const oldMarks = JSON.stringify({ version: 1, marks: { src: "excluded" } });
  window.localStorage.setItem(marksKey, oldMarks);
  const calls: unknown[][] = [];
  let menu!: ReturnType<typeof useFileExplorerContextMenu>;
  function Probe() {
    menu = useFileExplorerContextMenu({
      rootFolderPath: rootPath, canExcludeDirectory: () => false,
      isIndexExcluded: () => false, markForPath: () => "excluded",
      markDirectory: (...args) => { calls.push(args); },
      onFileSelect: () => {}, onDeleteRequested: () => {},
      onStartInlineEditing: () => {}, onOpenAllFilesInDirectory: async () => {},
    });
    return null;
  }
  try {
    await act(async () => renderer.render(createElement(LocaleProvider, { children: createElement(Probe) })));
    await act(async () => menu.setContextMenu({ x: 0, y: 0, path, isDir: true }));
    type Item = { id: string; onClick: () => void; children?: Item[] };
    const element = menu.contextMenuElement as import("react").ReactElement<{ children: Array<import("react").ReactElement<{ items: Item[] }> | null> }>;
    const markMenu = element.props.children[0]!.props.items.find((item) => item.id === "mark-directory")!;
    expect(markMenu.children!.map((item) => item.id)).toEqual(["mark-plain", "mark-sources", "mark-resources", "mark-module", "mark-package"]);
    markMenu.children!.find((item) => item.id === "mark-plain")!.onClick();
    expect(calls).toEqual([[path, "plain", false]]);
    expect(window.localStorage.getItem(marksKey)).toBe(oldMarks);
    expect(window.localStorage.getItem(indexingSettingsStorageKey(rootPath))).toBeNull();
  } finally {
    await act(async () => renderer.unmount());
    actGlobal.IS_REACT_ACT_ENVIRONMENT = previousAct;
  }
});
