import { expect, test } from "bun:test";
import {
  getFileTreeRefreshRequest,
  getMavenPomChangePath,
  getWorkspaceRootForChange,
  updatePendingWorkspaceRefresh,
} from "./file-watcher-listener";

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
