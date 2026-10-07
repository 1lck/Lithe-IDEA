import { beforeEach, describe, expect, mock, test } from "bun:test";

// Run this wiring test in its own process: the filesystem store owns native I/O.
let activeRoot: string | null = "/workspace";
mock.module("@/features/file-system/stores/file-system.store", () => ({
  useFileSystemStore: { getState: () => ({ rootFolderPath: activeRoot }) },
}));
const { openNewEntry, useNewEntryStore } = await import("./new-entry.store");
beforeEach(() => {
  activeRoot = "/workspace";
  useNewEntryStore.setState({ request: null });
});
describe("New entry workspace ownership", () => {
  test("File menu defaults to the active primary root", () => {
    expect(openNewEntry("java")).toBe(true);
    expect(useNewEntryStore.getState().request).toEqual({
      kind: "java",
      directory: "/workspace",
      workspaceRoot: "/workspace",
      sourceRoot: "/workspace",
    });
  });
  test("an attached module supplies context without replacing its workspace owner", () => {
    expect(openNewEntry("java", "/workspace/child", "/workspace/child")).toBe(true);
    expect(useNewEntryStore.getState().request).toEqual({
      kind: "java",
      directory: "/workspace/child",
      workspaceRoot: "/workspace",
      sourceRoot: "/workspace/child",
    });
  });
  test("Java package inference retains the attached module source root", () => {
    expect(openNewEntry("java", "/workspace/child/src/main/java/example", "/workspace/child")).toBe(
      true,
    );
    expect(useNewEntryStore.getState().request?.workspaceRoot).toBe("/workspace");
    expect(useNewEntryStore.getState().request?.sourceRoot).toBe("/workspace/child");
  });
  test("a tree context cannot invent an active workspace", () => {
    activeRoot = null;
    expect(openNewEntry("java", "/stale", "/stale")).toBe(false);
    expect(useNewEntryStore.getState().request).toBeNull();
  });
  test("remote source or target contexts never reach native local creation", () => {
    expect(openNewEntry("java", "/workspace", "remote://host/project")).toBe(false);
    expect(openNewEntry("java", "wsl://distro/project")).toBe(false);
    expect(useNewEntryStore.getState().request).toBeNull();
  });
});
