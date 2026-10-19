import { expect, test } from "bun:test";
import {
  getPathIdentity,
  getRelativePath,
  normalizePath,
  pathStartsWithRoot,
} from "./path-helpers";

test("path identity follows filesystem case rules", () => {
  expect(getPathIdentity("C:/Workspace/Project")).toBe("c:/workspace/project");
  expect(getPathIdentity("//server/share/Project")).toBe("//server/share/project");
  expect(getPathIdentity("/Project")).toBe("/Project");
  expect(getPathIdentity("wsl://Ubuntu/Project")).toBe("wsl://Ubuntu/Project");
  expect(getPathIdentity("//wsl.localhost/Ubuntu/Project")).toBe("//wsl.localhost/Ubuntu/Project");
});

test("containment compares native UNC case aliases while keeping provider paths distinct", () => {
  expect(
    pathStartsWithRoot("\\\\?\\UNC\\SERVER\\Share\\Project\\src", "//server/share/project"),
  ).toBe(true);
  expect(getRelativePath("//SERVER/SHARE/PROJECT/src", "//server/share/project")).toBe("src");
  expect(pathStartsWithRoot("//server/share/project-other/src", "//server/share/project")).toBe(
    false,
  );
  for (const root of [
    "/project",
    "wsl://Ubuntu/project",
    "remote://host/project",
    "//wsl$/Ubuntu/project",
  ]) {
    expect(pathStartsWithRoot(`${root}/src`, root)).toBe(true);
    expect(pathStartsWithRoot(`${root}/src`, `${root}/Src`)).toBe(false);
    expect(getRelativePath(`${root}/src`, root)).toBe("src");
  }
  expect(pathStartsWithRoot("/file", "/")).toBe(true);
  expect(getRelativePath("C:/file", "c:/")).toBe("file");
});

test("normalizes Windows verbatim drive paths before workspace comparisons", () => {
  const root = "C:/workspace";
  const changed = "\\\\?\\C:\\workspace\\src\\Main.java";

  expect(normalizePath(changed)).toBe("C:/workspace/src/Main.java");
  expect(pathStartsWithRoot(changed, root)).toBe(true);
  expect(getRelativePath(changed, root)).toBe("src/Main.java");
});

test("normalizes Windows verbatim UNC paths before workspace comparisons", () => {
  const root = "//server/share/workspace";
  const changed = "\\\\?\\UNC\\server\\share\\workspace\\pom.xml";

  expect(normalizePath(changed)).toBe("//server/share/workspace/pom.xml");
  expect(pathStartsWithRoot(changed, root)).toBe(true);
  expect(getRelativePath(changed, root)).toBe("pom.xml");
});

test("normalizes lowercase Windows verbatim UNC prefixes", () => {
  const root = "//server/share/workspace";
  const changed = "\\\\?\\unc\\server\\share\\workspace\\pom.xml";

  expect(normalizePath(changed)).toBe("//server/share/workspace/pom.xml");
  expect(pathStartsWithRoot(changed, root)).toBe(true);
  expect(getRelativePath(changed, root)).toBe("pom.xml");
});
