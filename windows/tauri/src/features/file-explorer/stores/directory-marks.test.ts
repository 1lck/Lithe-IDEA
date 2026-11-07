import { toast } from "sonner";
import rulesFixture from "../../../../../../shared/fixtures/workspace/directory-rules-v1.json";
import * as native from "@/platform/tauri-core";
import type { DirectoryAction } from "./directory-marks";
import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { useFileExplorerContextMenu } from "../hooks/use-file-explorer-context-menu";
import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { installHappyDom } from "@/test-utils/happy-dom";
import { IndexingSettingsError, indexingSettingsStorageKey, readIndexingSettings, writeIndexingSettings } from "./workspace-indexing";
import { directoryMarkRoot, markWorkspaceDirectory, migrateWorkspaceDirectoryMarks, migrateDirectoryMarks, readDirectoryMarks } from "./directory-marks";

let restore: () => void;
const storageKey = "lithe.workspace-directory-marks.c:/workspace";
beforeEach(() => {
  restore = installHappyDom();
});
afterEach(() => restore());

type Rules = { marks: Record<string, string>; includedDirectories: string[]; previousRoles: Record<string, string> };
interface ReduceCase {
  id: string;
  request: { path: string; action: DirectoryAction; caseInsensitive?: boolean; rules: Partial<Rules> };
  response: { changed: boolean; rules: Partial<Rules> };
}
interface RelocateCase {
  id: string;
  request: { source: string; destination?: string; caseInsensitive?: boolean; rules: Partial<Rules>; target?: Partial<Rules> };
  response: { rules: Partial<Rules>; target: Partial<Rules> | null };
}
const reduceCases = rulesFixture.reduce as unknown as ReduceCase[];
const relocateCases = rulesFixture.relocate as unknown as RelocateCase[];
const emptyRules = (rules: Partial<Rules> | undefined): Rules => ({
  marks: {}, includedDirectories: [], previousRoles: {}, ...rules,
});
// Requests are compared as Core reads them: omitted optional fields mean their defaults.
const sortKeys = (value: unknown): unknown =>
  Array.isArray(value) ? value.map(sortKeys)
    : value && typeof value === "object"
      ? Object.fromEntries(Object.entries(value).sort(([a], [b]) => a.localeCompare(b)).map(([key, item]) => [key, sortKeys(item)]))
      : value;
const canonical = (command: string, request: Record<string, unknown>) => JSON.stringify(sortKeys([command, {
  ...request,
  caseInsensitive: request.caseInsensitive ?? false,
  rules: emptyRules(request.rules as Partial<Rules>),
  ...(request.target ? { target: emptyRules(request.target as Partial<Rules>) } : {}),
}]));
const seed = (root: string, rules: Partial<Rules>) => {
  const full = emptyRules(rules);
  window.localStorage.setItem(`lithe.workspace-directory-marks.${root.toLowerCase()}`, JSON.stringify({ version: 1, marks: full.marks }));
  writeIndexingSettings(root, { gitIgnoreEnabled: false, includedDirectories: full.includedDirectories, previousRoles: full.previousRoles });
};
const stored = (root: string): Rules => ({
  marks: readDirectoryMarks(root),
  includedDirectories: readIndexingSettings(root).includedDirectories,
  previousRoles: readIndexingSettings(root).previousRoles,
});
/** Replays the fixture's Core answer for the request Windows built; any other request fails. */
const replayFixture = () => {
  const answers = new Map<string, unknown>();
  for (const item of reduceCases)
    answers.set(canonical("workspace.reduceDirectoryAction", item.request), item.response);
  for (const item of relocateCases)
    answers.set(canonical("workspace.relocateDirectoryRules", item.request), item.response);
  return spyOn(native, "invoke").mockImplementation((async (command: string, payload?: unknown) => {
    const answer = answers.get(canonical(command, payload as Record<string, unknown>));
    if (!answer) throw new Error(`Windows sent a request the fixture does not list: ${command} ${JSON.stringify(payload)}`);
    return answer;
  }) as typeof native.invoke);
};

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

test("volume-root marks keep their existing storage key", () => {
  window.localStorage.setItem(
    "lithe.workspace-directory-marks.c:",
    JSON.stringify({ version: 1, marks: { src: "sources" } }),
  );
  expect(readDirectoryMarks("C:/")).toEqual({ src: "sources" });
});

test("corrupt storage remains intact and legal dotted directory names are accepted", async () => {
  window.localStorage.setItem(storageKey, "broken");
  const invoke = spyOn(native, "invoke");
  await expect(migrateDirectoryMarks("C:/workspace", "C:/workspace/src")).rejects.toThrow();
  expect(invoke).not.toHaveBeenCalled();
  invoke.mockRestore();
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

test("indexing preferences do not overwrite marks for a similarly named workspace", () => {
  window.localStorage.setItem("lithe.workspace-directory-marks.c:/workspace.indexing", JSON.stringify({version: 1, marks: {src: "sources"}}));
  writeIndexingSettings("C:/workspace", {gitIgnoreEnabled: true, includedDirectories: [], previousRoles: {}});
  expect(readDirectoryMarks("C:/workspace.indexing")).toEqual({src: "sources"});
});


test.each(reduceCases.map((item) => [item.id, item] as const))(
  "reduce contract: %s",
  async (_id, item) => {
    const root = item.request.caseInsensitive ? "C:/contract" : "/contract";
    seed(root, item.request.rules);
    const invoke = replayFixture();
    try {
      await markWorkspaceDirectory([root], `${root}/${item.request.path}`, item.request.action);
      expect(stored(root)).toEqual(emptyRules(item.response.rules));
      expect(invoke).toHaveBeenCalledTimes(1);
    } finally {
      invoke.mockRestore();
    }
  },
);

test.each(relocateCases.filter((item) => !item.request.target).map((item) => [item.id, item] as const))(
  "relocate contract: %s",
  async (_id, item) => {
    const request = item.request;
    const root = request.caseInsensitive ? "C:/contract" : "/contract";
    seed(root, request.rules);
    const invoke = replayFixture();
    try {
      const destination = request.destination === undefined ? undefined
        : request.destination === "." ? root : `${root}/${request.destination}`;
      await migrateDirectoryMarks(root, `${root}/${request.source}`, destination);
      expect(stored(root)).toEqual(emptyRules(item.response.rules));
    } finally {
      invoke.mockRestore();
    }
  },
);

test("a move between workspace roots sends both roots' rules and stores both results", async () => {
  const item = relocateCases.find((entry) => entry.id === "move-across-workspace-roots")!;
  seed("C:/main", item.request.rules);
  seed("D:/added", item.request.target!);
  const invoke = replayFixture();
  try {
    await migrateWorkspaceDirectoryMarks(["C:/main", "D:/added"], "C:/main/pkg", "D:/added/vendor/pkg");
    expect(stored("C:/main")).toEqual(emptyRules(item.response.rules));
    expect(stored("D:/added")).toEqual(emptyRules(item.response.target!));
  } finally {
    invoke.mockRestore();
  }
});

test("an unchanged answer writes nothing and a path outside every root is refused", async () => {
  const blocked = reduceCases.find((entry) => entry.id === "manual-ancestor-exclusion-cannot-be-overridden")!;
  seed("/contract", blocked.request.rules);
  const invoke = replayFixture();
  const changes: string[] = [];
  const listener = (event: Event) => changes.push(event.type);
  window.addEventListener("lithe:directory-marks-changed", listener);
  window.addEventListener("lithe:workspace-indexing-changed", listener);
  try {
    await markWorkspaceDirectory(["/contract"], "/contract/vendor/lib", { kind: "cancelExclusion" });
    expect(changes).toEqual([]);
    await expect(markWorkspaceDirectory(["/contract"], "/elsewhere/dir", { kind: "exclude" })).rejects.toThrow();
  } finally {
    invoke.mockRestore();
    window.removeEventListener("lithe:directory-marks-changed", listener);
    window.removeEventListener("lithe:workspace-indexing-changed", listener);
  }
});

test("a destination outside the root is sent as a deletion", async () => {
  seed("C:/main", { marks: { src: "sources" } });
  const invoke = spyOn(native, "invoke").mockImplementation((async () => ({ rules: emptyRules({}) })) as typeof native.invoke);
  try {
    await migrateDirectoryMarks("C:/main", "C:/main/src", "D:/elsewhere/src");
    expect(invoke.mock.calls[0]?.[1]).toEqual({
      source: "src", destination: undefined, caseInsensitive: true, rules: emptyRules({ marks: { src: "sources" } }),
    });
    expect(readDirectoryMarks("C:/main")).toEqual({});
  } finally {
    invoke.mockRestore();
  }
});

test("cross-root quota failure rolls back in reverse order without publishing partial state", async () => {
  const roots = ["C:/main", "D:/added"];
  seed("D:/added", { marks: { "long-directory-name": "excluded" }, previousRoles: { "long-directory-name": "sources" } });
  const invoke = spyOn(native, "invoke").mockImplementation((async () => ({
    rules: emptyRules({}),
    target: emptyRules({ marks: { code: "excluded" }, previousRoles: { code: "sources" } }),
  })) as typeof native.invoke);
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
    await expect(migrateWorkspaceDirectoryMarks(roots, "D:/added/long-directory-name", "C:/main/code")).rejects.toThrow();
    expect(rejected).toBe(true);
    expect(keys.map((key) => storage.getItem(key))).toEqual(before);
    expect(published).toBe(0);
  } finally {
    invoke.mockRestore();
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
    expect(calls).toEqual([[path, { kind: "setRole", role: "plain" }]]);
    expect(window.localStorage.getItem(marksKey)).toBe(oldMarks);
    expect(window.localStorage.getItem(indexingSettingsStorageKey(rootPath))).toBeNull();
  } finally {
    await act(async () => renderer.unmount());
    actGlobal.IS_REACT_ACT_ENVIRONMENT = previousAct;
  }
});

test.each([
  ["zh-CN", "项目索引设置格式无效，原始设置已保留。"],
  ["en-US", "Project indexing settings are invalid. The saved data has been preserved."],
] as const)("directory menu translates real corrupt settings in %s and permits retry", async (language, message) => {
  const environment = globalThis as typeof globalThis & {IS_REACT_ACT_ENVIRONMENT?: boolean};
  const previous = environment.IS_REACT_ACT_ENVIRONMENT;
  environment.IS_REACT_ACT_ENVIRONMENT = true;
  const renderer = createRoot(document.createElement("div"));
  const rootPath = "C:/menu-errors";
  const key = indexingSettingsStorageKey(rootPath);
  window.localStorage.setItem(key, "{}");
  const error = spyOn(toast, "error").mockReturnValue(0);
  const invoke = spyOn(native, "invoke").mockImplementation((async () => ({
    changed: true, rules: emptyRules({ marks: { archive: "sources" } }),
  })) as typeof native.invoke);
  let notifications = 0;
  const changed = () => notifications++;
  window.addEventListener("lithe:directory-marks-changed", changed);
  let menu!: ReturnType<typeof useFileExplorerContextMenu>;
  function Probe() {
    menu = useFileExplorerContextMenu({rootFolderPath: rootPath, canExcludeDirectory: () => true,
      isIndexExcluded: () => false, markDirectory: (path, action) => markWorkspaceDirectory([rootPath], path, action),
      onFileSelect: () => {}, onDeleteRequested: () => {}, onStartInlineEditing: () => {}, onOpenAllFilesInDirectory: async () => {}});
    return null;
  }
  try {
    await act(async () => renderer.render(createElement(LocaleProvider, {language, children: createElement(Probe)})));
    await act(async () => menu.setContextMenu({x: 0, y: 0, path: `${rootPath}/archive`, isDir: true}));
    type Item = {id: string; onClick: () => void; children?: Item[]};
    const element = menu.contextMenuElement as import("react").ReactElement<{children: Array<import("react").ReactElement<{items: Item[]}>>}>;
    const mark = element.props.children[0]!.props.items.find((item) => item.id === "mark-directory")!.children!.find((item) => item.id === "mark-sources")!;
    mark.onClick();
    await act(async () => {});
    expect(error.mock.calls[0]?.[1]?.description).toBe(message);
    expect(window.localStorage.getItem(key)).toBe("{}"); expect(notifications).toBe(0);
    window.localStorage.removeItem(key);
    mark.onClick();
    await act(async () => {});
    expect(readDirectoryMarks(rootPath).archive).toBe("sources");
    expect(error).toHaveBeenCalledTimes(1); expect(notifications).toBe(1);
  } finally {
    await act(async () => renderer.unmount()); error.mockRestore(); invoke.mockRestore();
    window.removeEventListener("lithe:directory-marks-changed", changed);
    environment.IS_REACT_ACT_ENVIRONMENT = previous;
  }
});
