import { expect, mock, spyOn, test } from "bun:test";
import * as nativeEvents from "@tauri-apps/api/event";
import * as nativePaths from "@tauri-apps/api/path";
import * as documentWatches from "@/features/editor/services/document-watch-controller";
import * as gitEvents from "@/features/git/events/git-events";
import * as indexing from "@/features/file-explorer/stores/workspace-indexing";
import * as scheduler from "./file-watcher-refresh-scheduler";
import * as javaChanges from "@/features/editor/lsp/java-workspace-change-scheduler";
import { workspaceRuntimeRegistry as registry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { useFileSystemStore } from "../stores/file-system.store";
import { useMavenStore } from "@/features/maven/stores/maven.store";
import { installHappyDom } from "@/test-utils/happy-dom";
import {
  getFileTreeRefreshRequest,
  getMavenPomChangePath,
  getWorkspaceRootForChange,
  updatePendingWorkspaceRefresh,
  initializeFileWatcherListener,
  cleanupFileWatcherListener,
} from "./file-watcher-listener";

test.each(["Keep.java", "pom.xml"])("indexing failure preserves watcher tree and Maven updates: %s", async (name) => {
  const restoreDOM = installHappyDom();
  const previousCustomEvent = globalThis.CustomEvent;
  globalThis.CustomEvent = window.CustomEvent;
  const previous = registry.getActiveWorkspace()!;
  const id = `indexing-failure-${name}`;
  registry.activateWorkspace({ id, name: id }, "ready");
  const refresh = mock(async () => undefined);
  useFileSystemStore.getStore(id).setState({ rootFolderPath: "C:/watch", workspaceFolders: [], refreshDirectory: refresh });
  const pending: Array<() => void | Promise<void>> = [];
  type Payload = { path: string; event_type: "opened" };
  let receive: nativeEvents.EventCallback<Payload> | undefined;
  const spies = [
    spyOn(documentWatches, "initializeDocumentWatches").mockResolvedValue(undefined),
    spyOn(documentWatches, "cleanupDocumentWatches").mockResolvedValue(undefined),
    spyOn(gitEvents, "subscribeToGitChanges").mockReturnValue(() => {}),
    spyOn(nativeEvents, "listen").mockImplementation(async (event, handler) => {
      if (event === "file-changed") receive = handler as nativeEvents.EventCallback<Payload>;
      return () => {};
    }),
    spyOn(nativePaths, "dirname").mockResolvedValue("C:/watch/src"),
    spyOn(indexing, "configureWorkspaceIndexing").mockRejectedValue(new indexing.IndexingSettingsError("readFailed")),
    spyOn(scheduler, "scheduleFileWatcherRefresh").mockImplementation((_id, _path, callback) => { pending.push(callback); }),
  ];
  const java = spyOn(javaChanges, "scheduleJavaWorkspaceChange").mockImplementation(() => {});
  const pom = spyOn(useMavenStore.getStore(id).getState().actions, "markPomReloadRequired").mockImplementation(() => {});
  const diagnostic = spyOn(console, "error").mockImplementation(() => {});
  try {
    await initializeFileWatcherListener();
    expect(receive).toBeDefined();
    await receive!({ event: "file-changed", id: 0, payload: { path: `C:/watch/src/${name}`, event_type: "opened" } });
    expect(pending).toHaveLength(1);
    await pending[0]!();
    expect(refresh).toHaveBeenCalledWith("C:/watch/src", { force: true });
    expect(java).not.toHaveBeenCalled();
    if (name === "pom.xml") expect(pom).toHaveBeenCalledWith("src/pom.xml");
    else expect(pom).not.toHaveBeenCalled();
    expect(diagnostic).toHaveBeenCalledTimes(1);
  } finally {
    await cleanupFileWatcherListener();
    registry.activateWorkspace(previous.descriptor, previous.status);
    registry.removeWorkspace(id);
    diagnostic.mockRestore(); pom.mockRestore(); java.mockRestore();
    for (const spy of spies.reverse()) spy.mockRestore();
    globalThis.CustomEvent = previousCustomEvent;
    restoreDOM();
  }
});

test("returns workspace-relative Maven descriptors from the active Windows workspace", () => {
  expect(getMavenPomChangePath("D:\\work\\pom.xml", "D:\\work")).toBe("pom.xml");
  expect(getMavenPomChangePath("D:\\work\\module\\POM.XML", "D:\\work")).toBe("module/POM.XML");
});

test("rejects Maven descriptors from another workspace or a sibling path", () => {
  expect(getMavenPomChangePath("D:\\work-b\\pom.xml", "D:\\work-a")).toBeNull();
  expect(getMavenPomChangePath("D:\\workspace-copy\\pom.xml", "D:\\workspace")).toBeNull();
  expect(getMavenPomChangePath("D:\\workspace\\module\\build.gradle", "D:\\workspace")).toBeNull();
});

test("routes nested changes to the most specific workspace root", () => {
  expect(
    getWorkspaceRootForChange("D:\\work\\module\\src\\Main.java", "D:\\work", [
      "D:\\work",
      "D:\\work\\module",
    ]),
  ).toBe("D:\\work\\module");
});

test("rejects changes outside every workspace root", () => {
  expect(
    getWorkspaceRootForChange("D:\\unrelated\\Main.java", "D:\\work", [
      "D:\\work",
      "E:\\shared",
    ]),
  ).toBeNull();
});

test("refreshes the containing directory for external deletes and rename sides", () => {
  expect(getFileTreeRefreshRequest("deleted", "D:\\work", "D:\\work\\src")).toEqual({
    fullRescan: false,
    directoryPath: "D:\\work\\src",
  });
  expect(getFileTreeRefreshRequest("opened", "D:\\work", "D:\\work\\src")).toEqual({
    fullRescan: false,
    directoryPath: "D:\\work\\src",
  });
  expect(getFileTreeRefreshRequest("reloaded", "D:\\work", "D:\\work\\src")).toBeNull();
});

test("falls back to a full workspace refresh after event loss or root removal", () => {
  expect(getFileTreeRefreshRequest("rescan", "D:\\work")).toEqual({ fullRescan: true });
  expect(getFileTreeRefreshRequest("deleted", "D:\\work", "D:\\")).toEqual({
    fullRescan: true,
  });
});

test("bounds pending directory refreshes before falling back to a workspace rescan", () => {
  const pending = { directories: new Set<string>(), fullRescan: false };
  updatePendingWorkspaceRefresh(pending, "D:\\work", "D:\\work\\one", 2);
  updatePendingWorkspaceRefresh(pending, "D:\\work", "D:\\work\\two", 2);

  expect(pending).toEqual({
    directories: new Set(["D:\\work\\one", "D:\\work\\two"]),
    fullRescan: false,
  });

  updatePendingWorkspaceRefresh(pending, "D:\\work", "D:\\work\\three", 2);
  expect(pending).toEqual({ directories: new Set(), fullRescan: true });
});
