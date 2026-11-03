import { describe, expect, test } from "bun:test";
import type { GitDiff } from "@/features/git/types/git.types";
import { adaptCoreResult } from "./core-result-adapter";
import { createGitHunk, groupLinesIntoHunks } from "@/features/git/utils/git-diff-helpers";

const header = "@@ -1 +1 @@";
const rawPatch = `diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n${header}\n-old\r\n+new\r\n`;
const file = {
  path: "a.txt", status: "M", patch: rawPatch, hasLossyLineEndings: true,
  additions: 1, deletions: 1, isBinary: false,
  lines: [{lineType: "header", content: header}, {lineType: "removed", content: "old", oldLine: 1},
    {lineType: "added", content: "new", newLine: 1}],
  rows: [{kind: "information", left: header}, {kind: "changed", left: "old\r", right: "new\r", oldLine: 1, newLine: 1}],
  hunks: [{id: "hunk-0", header, patch: rawPatch}],
};

describe("structured Core diff adaptation", () => {
  test("preserves file order, visual rows and exact hunk bytes", () => {
    const diffs = adaptCoreResult<GitDiff[]>("git.diff", {}, {files: [file, {...file, path: "b.txt"}]});
    expect(diffs.map((diff) => diff.file_path)).toEqual(["a.txt", "b.txt"]);
    expect(diffs[0].split_hunks?.[0]?.[0]?.kind).toBe("changed");
    const hunks = groupLinesIntoHunks(diffs[0].lines, diffs[0].core_hunks);
    expect(createGitHunk(hunks[0], "a.txt").rawPatch).toBe(rawPatch);
    expect(diffs[0].has_lossy_line_endings).toBe(true);
  });

  test("never supplies a writable hunk after invalid UTF-8 decoding", () => {
    const diff = adaptCoreResult<GitDiff>("git_diff_file", {}, {files: [file], hasDecodingLoss: true});
    expect(diff.has_decoding_loss).toBe(true);
    expect(diff.core_hunks).toBeUndefined();
  });

  test("keeps a genuine replacement character writable when Core decoded losslessly", () => {
    const diff = adaptCoreResult<GitDiff>("git_diff_file", {}, {files: [{...file, patch: `${rawPatch}�`}], hasDecodingLoss: false});
    expect(diff.has_decoding_loss).toBe(false);
    expect(diff.core_hunks).toHaveLength(1);
  });

  test("does not associate mismatched Core hunk headers with display rows", () => {
    const diff = adaptCoreResult<GitDiff>("git_diff_file", {}, {files: [file]});
    expect(groupLinesIntoHunks(diff.lines, [{id: "other", header: "@@ -2 +2 @@", patch: rawPatch}])[0].rawPatch).toBeUndefined();
  });

  test("maps untracked binary identity and counts", () => {
    const diff = adaptCoreResult<GitDiff>("git_diff_file", {}, {files: [{path: "image.png", status: "A", isBinary: true, lines: [], rows: [], hunks: []}]});
    expect(diff.is_new).toBe(true);
    expect(diff.is_binary).toBe(true);
    expect(diff.lines).toEqual([]);
  });

  test("uses Core's invisible row marker for displayed statistics", () => {
    const invisible = {...file, rows: [{kind: "information", left: header},
      {kind: "changed", left: "same", right: "same\r", oldLine: 1, newLine: 1, isInvisibleChange: true}]};
    const stats = adaptCoreResult("git_status_diff_stats", {staged: true}, {files: [invisible]});
    expect(stats).toEqual([{file_path: "a.txt", staged: true, additions: 0, deletions: 0}]);
  });

  test("keeps compact Core numstat responses", () => {
    const stats = adaptCoreResult("git_status_diff_stats", {staged: false}, {files: [{path: "a.txt", additions: 2, deletions: 1}]});
    expect(stats).toEqual([{file_path: "a.txt", staged: false, additions: 2, deletions: 1}]);
  });
});
