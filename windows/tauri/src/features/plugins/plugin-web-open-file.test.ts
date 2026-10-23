import { expect, test } from "bun:test";
import { normalizeWorkspacePath, pathIsInsideWorkspace } from "./plugin-web-path";

test("normalizes path components before enforcing the workspace boundary", () => {
  expect(normalizeWorkspacePath("C:/work/src/../src/main.php")).toBe("C:/work/src/main.php");
  expect(pathIsInsideWorkspace("C:/work/src/../src/main.php", "C:/work")).toBe(true);
  expect(pathIsInsideWorkspace("C:/work/../outside.txt", "C:/work")).toBe(false);
  expect(pathIsInsideWorkspace("C:/workspace/file.php", "C:/work")).toBe(false);
  expect(pathIsInsideWorkspace("relative/file.php", "C:/work")).toBe(false);
});
