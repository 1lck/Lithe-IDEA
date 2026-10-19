import { afterEach, beforeEach, expect, test } from "bun:test";
import { installHappyDom } from "@/test-utils/happy-dom";
import { migrateDirectoryMarks, readDirectoryMarks } from "./directory-marks";

let restore: () => void;
const storageKey = "lithe.workspace-directory-marks.c:/workspace";
beforeEach(() => {
  restore = installHappyDom();
});
afterEach(() => restore());

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
