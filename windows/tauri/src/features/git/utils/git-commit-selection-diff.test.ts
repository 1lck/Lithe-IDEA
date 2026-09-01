import { describe, expect, test } from "bun:test";
import type { GitCommit, GitDiff } from "../types/git.types";
import {
  aggregateSelectedCommitFileRows,
  aggregateSelectedCommitDiffs,
  gitDiffsToCommitFiles,
  resolveGitCommitSelectionDiff,
} from "./git-commit-selection-diff";

const commit = (hash: string, parentHashes: string[] = []): GitCommit => ({
  hash,
  shortHash: hash.slice(0, 7),
  parentHashes,
  message: hash,
  author: "Lithe Test",
  date: "2026-09-01T00:00:00Z",
  decorations: "",
});

const diff = (overrides: Partial<GitDiff>): GitDiff => ({
  file_path: "src/file.ts",
  is_new: false,
  is_deleted: false,
  is_renamed: false,
  lines: [],
  ...overrides,
});

describe("Git commit selection diff", () => {
  test("compares the oldest first parent with the newest selected commit", () => {
    const newest = commit("ccccccc", ["bbbbbbb"]);
    const middle = commit("bbbbbbb", ["aaaaaaa"]);
    const oldest = commit("aaaaaaa", ["parent0"]);

    expect(resolveGitCommitSelectionDiff([newest, middle, oldest])).toEqual({
      kind: "range",
      baseRef: "parent0",
      targetRef: "ccccccc",
      oldest,
      newest,
    });
  });

  test("leaves empty-tree resolution to Core when a selection includes the root commit", () => {
    const newest = commit("bbbbbbb", ["aaaaaaa"]);
    const root = commit("aaaaaaa");

    expect(resolveGitCommitSelectionDiff([newest, root])).toMatchObject({
      kind: "range",
      baseRef: null,
      targetRef: "bbbbbbb",
    });
  });

  test("does not include unselected commits in a non-contiguous or nonlinear selection", () => {
    const newest = commit("ddddddd", ["ccccccc"]);
    const selectedOlder = commit("bbbbbbb", ["aaaaaaa"]);

    expect(resolveGitCommitSelectionDiff([newest, selectedOlder])).toEqual({
      kind: "selection",
      commits: [newest, selectedOlder],
    });
  });

  test("aggregates nonlinear file rows without loading full diffs", () => {
    expect(
      aggregateSelectedCommitFileRows([
        { files: [{ path: "src/shared.ts", status: "M" }] },
        {
          files: [
            { path: "src/older.ts", status: "D" },
            { path: "src/shared.ts", status: "A" },
          ],
        },
      ]),
    ).toEqual([
      { path: "src/older.ts", status: "D" },
      { path: "src/shared.ts", status: "M" },
    ]);
  });

  test("preserves every selected commit diff while aggregating nonlinear file rows", () => {
    const newest = commit("ddddddd", ["ccccccc"]);
    const selectedOlder = commit("bbbbbbb", ["aaaaaaa"]);
    const newestShared = diff({ file_path: "src/shared.ts" });
    const newestOnly = diff({ file_path: "src/newest.ts", is_new: true });
    const olderOnly = diff({ file_path: "src/older.ts", is_deleted: true });
    const olderShared = diff({ file_path: "src/shared.ts", is_new: true });
    const result = aggregateSelectedCommitDiffs([
      {
        commit: newest,
        diffs: [newestShared, newestOnly],
      },
      {
        commit: selectedOlder,
        diffs: [olderOnly, olderShared],
      },
    ]);

    expect(result.files).toEqual([
      { path: "src/newest.ts", status: "A" },
      { path: "src/older.ts", status: "D" },
      { path: "src/shared.ts", status: "M" },
    ]);
    expect(result.diffs).toEqual([newestShared, newestOnly, olderOnly, olderShared]);
    expect(result.fileKeys).toEqual([
      "ddddddd:src/shared.ts:0",
      "ddddddd:src/newest.ts:1",
      "bbbbbbb:src/older.ts:0",
      "bbbbbbb:src/shared.ts:1",
    ]);
    expect(result.fileLabels).toEqual(["ddddddd", "ddddddd", "bbbbbbb", "bbbbbbb"]);
  });

  test("keeps a single selection on the existing commit diff path", () => {
    const selected = commit("aaaaaaa");
    expect(resolveGitCommitSelectionDiff([selected])).toEqual({ kind: "commit", commit: selected });
    expect(resolveGitCommitSelectionDiff([])).toBeNull();
  });

  test("projects a cumulative range diff into deterministic commit-file rows", () => {
    expect(
      gitDiffsToCommitFiles([
        diff({ file_path: "src/modified.ts" }),
        diff({ file_path: "src/deleted.ts", is_deleted: true }),
        diff({ file_path: "src/added.ts", is_new: true }),
        diff({
          file_path: "src/new-name.ts",
          old_path: "src/old-name.ts",
          new_path: "src/new-name.ts",
          is_renamed: true,
        }),
      ]),
    ).toEqual([
      { path: "src/added.ts", status: "A" },
      { path: "src/deleted.ts", status: "D" },
      { path: "src/modified.ts", status: "M" },
      { path: "src/new-name.ts", status: "R" },
    ]);
  });
});
