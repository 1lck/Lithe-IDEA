import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import * as dialog from "@/ui/dialog";
import * as core from "@/core/lithe-core-client";
import * as virtualization from "@tanstack/react-virtual";
import * as indexing from "@/features/file-explorer/stores/workspace-indexing";
import { readDirectoryMarks } from "@/features/file-explorer/stores/directory-marks";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { WorkspaceStoreScopeContext } from "@/features/workspace/stores/create-workspace-scoped-store";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import { IgnoredDirectoryNotice } from "./ignored-directory-notice";

const workspaceId = "ignored-directory-notice-fixture";
const project = "C:/fixture";
let host: HTMLDivElement;
let root: Root;
let restoreDom: () => void;
let previousAct: boolean | undefined;
const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
const spies: { mockRestore(): void }[] = [];
let query: ReturnType<typeof spyOn<typeof indexing, "queryIgnoredDirectorySuggestions">>;

beforeEach(() => {
  restoreDom = installHappyDom();
  previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  environment.IS_REACT_ACT_ENVIRONMENT = true;
  spies.push(
    spyOn(core, "executeCore").mockResolvedValue({
      id: "fixture",
      ok: true,
      data: { revision: 1, excludedDirectories: {}, gitIgnoreFailed: false },
    }),
    spyOn(dialog, "default").mockImplementation(({ children, footer }) => (
      <div role="dialog">
        {children}
        {footer}
      </div>
    )),
  );
  useFileSystemStore
    .getStore(workspaceId)
    .setState({ rootFolderPath: project, workspaceFolders: [] });
  workspaceRuntimeRegistry.updateWorkspaceStatus(workspaceId, "ready");
  query = spyOn(indexing, "queryIgnoredDirectorySuggestions").mockResolvedValue({
    directories: ["archive", "cache"],
    incomplete: false,
    gitIgnoreFailed: false,
  });
  spies.push(
    query,
    spyOn(virtualization, "useVirtualizer").mockImplementation(((options: { count: number }) => ({
      getTotalSize: () => options.count * 28,
      getVirtualItems: () =>
        Array.from({ length: options.count }, (_, index) => ({
          index,
          key: index,
          start: index * 28,
          size: 28,
        })),
    })) as unknown as typeof virtualization.useVirtualizer),
  );
  host = document.createElement("div");
  document.body.append(host);
  root = createRoot(host);
});
afterEach(async () => {
  try {
    await act(async () => root.unmount());
  } finally {
    host.remove();
    spies
      .splice(0)
      .reverse()
      .forEach((spy) => spy.mockRestore());
    workspaceRuntimeRegistry.resetForTests();
    environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
    restoreDom();
  }
});
async function render(path = `${project}/.gitignore`) {
  await act(async () =>
    root.render(
      <WorkspaceStoreScopeContext.Provider value={workspaceId}>
        <LocaleProvider language="zh-CN">
          <IgnoredDirectoryNotice filePath={path} />
        </LocaleProvider>
      </WorkspaceStoreScopeContext.Provider>,
    ),
  );
}
const button = (text: string) =>
  Array.from(document.querySelectorAll<HTMLButtonElement>("button")).find(
    (node) => node.textContent === text,
  )!;

test("opening an ignore file is read-only; confirming excludes only selected directories", async () => {
  await render();
  expect(host.textContent).toContain("部分被忽略的目录");
  expect(readDirectoryMarks(project)).toEqual({});
  expect(window.localStorage.getItem(indexing.indexingSettingsStorageKey(project))).toBeNull();
  await act(async () => button("查看目录").click());
  const choices = document.querySelectorAll<HTMLElement>('[role="checkbox"]');
  await act(async () => choices[1]!.click());
  await act(async () => button("排除所选目录").click());
  expect(readDirectoryMarks(project)).toEqual({ archive: "excluded" });
  expect(indexing.readIndexingSettings(project).includedDirectories).toEqual([]);
});

test("dismissal survives remount and normal files never query directories", async () => {
  await render(`${project}/readme.md`);
  expect(query).not.toHaveBeenCalled();
  await render();
  await act(async () => button("不再显示").click());
  const calls = query.mock.calls.length;
  await render(`${project}/readme.md`);
  await render();
  expect(query).toHaveBeenCalledTimes(calls);
  expect(host.textContent).toBe("");
  expect(indexing.readIndexingSettings(project).ignoredDirectoryNoticeDismissed).toBe(true);
  expect(indexing.readIndexingSettings("C:/other").ignoredDirectoryNoticeDismissed).not.toBe(true);
});

test("failed multi-selection saves nothing, publishes no change and preserves the picker", async () => {
  await render();
  await act(async () => button("查看目录").click());
  let publications = 0;
  const observe = () => { publications += 1; };
  window.addEventListener(indexing.indexingEvent, observe);
  const storage = window.localStorage;
  const write = storage.setItem.bind(storage);
  const descriptor = Object.getOwnPropertyDescriptor(window, "localStorage");
  let rejected = false;
  Object.defineProperty(window, "localStorage", { configurable: true, value: {
    getItem: storage.getItem.bind(storage), removeItem: storage.removeItem.bind(storage),
    setItem: (key: string, value: string) => {
      if (key.includes("directory-marks") && value.includes('"cache":"excluded"')) {
        rejected = true;
        throw new Error("fixture storage quota exceeded");
      }
      write(key, value);
    },
  } });
  try {
    await act(async () => button("排除所选目录").click());
    expect(rejected).toBe(true);
    expect(readDirectoryMarks(project)).toEqual({});
    expect(storage.getItem(indexing.indexingSettingsStorageKey(project))).toBeNull();
    expect(publications).toBe(0);
    expect(document.querySelector('[role="dialog"]')).not.toBeNull();
    expect(document.querySelectorAll('[role="checkbox"]')).toHaveLength(2);
    expect(button("排除所选目录").disabled).toBe(false);
  } finally {
    if (descriptor) Object.defineProperty(window, "localStorage", descriptor);
    else Reflect.deleteProperty(window, "localStorage");
    window.removeEventListener(indexing.indexingEvent, observe);
  }
});

test("late inspection cannot show another file's banner", async () => {
  let finish!: (value: indexing.IgnoredDirectorySuggestions) => void;
  const pending = new Promise<indexing.IgnoredDirectorySuggestions>((resolve) => {
    finish = resolve;
  });
  query.mockReturnValue(pending);
  try {
    await render();
    await render(`${project}/readme.md`);
    await act(async () =>
      finish({ directories: ["stale"], incomplete: false, gitIgnoreFailed: false }),
    );
    expect(host.textContent).toBe("");
    expect(readDirectoryMarks(project)).toEqual({});
  } finally {
    finish({ directories: [], incomplete: false, gitIgnoreFailed: false });
  }
});
