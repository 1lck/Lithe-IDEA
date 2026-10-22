import { expect, test } from "bun:test";
import { gitFileTreeOrder, orderGitDiffsForTree } from "./git-file-tree-order";
import type { GitDiff } from "../types/git.types";

const diff = (filePath: string): GitDiff => ({
  file_path: filePath,
  is_new: false,
  is_deleted: false,
  is_renamed: false,
  lines: [],
});

test("tree order places directories before files and compares names naturally", () => {
  const paths = ["a.md", "a/b.txt", "a/file2", "a/file10", "B.txt"];
  expect(gitFileTreeOrder(paths, (path) => path).map((index) => paths[index])).toEqual([
    "a/b.txt",
    "a/file2",
    "a/file10",
    "a.md",
    "B.txt",
  ]);
});

test("repeated paths keep their input order and pathless entries trail", () => {
  const items = ["a.ts", "b.ts", "a.ts", ""];
  expect(gitFileTreeOrder(items, (item) => item)).toEqual([0, 2, 1, 3]);
  const diffs = [diff("a.ts"), diff("b.ts"), diff("a.ts")];
  expect(orderGitDiffsForTree(diffs).map((entry) => entry.file_path)).toEqual([
    "a.ts",
    "a.ts",
    "b.ts",
  ]);
});
