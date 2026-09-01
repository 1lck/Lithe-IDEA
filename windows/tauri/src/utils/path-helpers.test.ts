import { expect, test } from "bun:test";
import { getRelativePath, normalizePath, pathStartsWithRoot } from "./path-helpers";

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
