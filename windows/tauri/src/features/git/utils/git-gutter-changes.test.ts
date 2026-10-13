import { describe, expect, test } from "bun:test";
import { monacoLineDiff } from "@/features/editor/engines/monaco/monaco-line-diff";
import type { GitDiff, GitDiffLine } from "../types/git.types";
import {
  adjacentGitGutterChangeIndex,
  isGitGutterFileUntracked,
  type GitGutterChange,
  computeGitGutterChanges,
  gitGutterBaseFromDiff,
  gitGutterChangeHunk,
  gitGutterChangeIndexAtLine,
  gitGutterMarkerLines,
  gitGutterPeekAnchorLine,
  gitGutterPeekRows,
  splitGitGutterLines,
} from "./git-gutter-changes";

const changesOf = (base: string[], editor: string[]) =>
  computeGitGutterChanges(base, editor, monacoLineDiff) ?? [];

const fullContextDiff = (lines: GitDiffLine[], header: string): GitDiff => ({
  file_path: "src/app.ts",
  is_new: false,
  is_deleted: false,
  is_renamed: false,
  is_full_context: true,
  lines: [{ line_type: "header", content: header }, ...lines],
});

describe("Git gutter change locations", () => {
  test("classifies added, modified and deleted lines against the base", () => {
    const changes = changesOf(
      ["a", "b", "c", "d", "e"],
      ["a", "B", "c", "e", "f"],
    );

    expect(changes.map((change) => change.kind)).toEqual(["modified", "deleted", "added"]);
    expect(changes[0]).toMatchObject({ originalLines: ["b"], modifiedLines: ["B"], modifiedStart: 2 });
    expect(changes[1]).toMatchObject({ originalLines: ["d"], modifiedLines: [], modifiedStart: 4 });
    expect(changes[2]).toMatchObject({ originalLines: [], modifiedLines: ["f"], modifiedStart: 5 });
  });

  test("marks a deletion on the following line, or the last line at end of file", () => {
    const [middle] = changesOf(["a", "b", "c"], ["a", "c"]);
    const [end] = changesOf(["a", "b", "c"], ["a", "b"]);

    expect(gitGutterMarkerLines(middle, 2)).toEqual({ start: 2, end: 2 });
    expect(gitGutterMarkerLines(end, 2)).toEqual({ start: 2, end: 2 });
    expect(gitGutterPeekAnchorLine(middle)).toBe(1);
    expect(gitGutterPeekAnchorLine(end)).toBe(2);
  });

  test("resolves a clicked line to the change that owns it", () => {
    const changes = changesOf(["a", "b", "c", "d"], ["a", "x", "y", "d", "z"]);
    expect(gitGutterChangeIndexAtLine(changes, 3, 5)).toBe(0);
    expect(gitGutterChangeIndexAtLine(changes, 5, 5)).toBe(1);
    expect(gitGutterChangeIndexAtLine(changes, 4, 5)).toBe(-1);
  });

  test("selects a deletion through the line that follows it", () => {
    // "b" is deleted, so its marker sits on "c" (line 2); "x" is a separate addition.
    const changes = changesOf(["a", "b", "c"], ["a", "c", "x"]);
    expect(changes.map((change) => change.kind)).toEqual(["deleted", "added"]);
    expect(gitGutterChangeIndexAtLine(changes, 2, 3)).toBe(0);
    expect(gitGutterChangeIndexAtLine(changes, 3, 3)).toBe(1);
  });

  test("a modification wins over a deletion marked on the same line", () => {
    const changes: GitGutterChange[] = [
      { kind: "deleted", originalStart: 2, originalEnd: 3, modifiedStart: 2, modifiedEnd: 2,
        originalLines: ["b"], modifiedLines: [] },
      { kind: "modified", originalStart: 3, originalEnd: 4, modifiedStart: 2, modifiedEnd: 3,
        originalLines: ["c"], modifiedLines: ["C"] },
    ];
    expect(gitGutterChangeIndexAtLine([...changes], 2, 3)).toBe(1);
  });

  test("wraps previous and next navigation around the change list", () => {
    expect(adjacentGitGutterChangeIndex(3, 2, "next")).toBe(0);
    expect(adjacentGitGutterChangeIndex(3, 0, "previous")).toBe(2);
    expect(adjacentGitGutterChangeIndex(3, 1, "next")).toBe(2);
    expect(adjacentGitGutterChangeIndex(0, 0, "next")).toBe(-1);
  });

  test("compares an empty base or editor without calling the line diff", () => {
    expect(changesOf([], ["a", "b"])).toEqual([
      expect.objectContaining({ kind: "added", modifiedStart: 1, modifiedEnd: 3 }),
    ]);
    expect(changesOf(["a"], [])).toEqual([
      expect.objectContaining({ kind: "deleted", originalStart: 1, originalEnd: 2 }),
    ]);
    expect(changesOf([], [])).toEqual([]);
  });

  test("shows no markers when the comparison exceeds its budget", () => {
    expect(computeGitGutterChanges(["a"], ["b"], () => null)).toBeNull();
  });
});

describe("Git gutter comparison base", () => {
  test("rebuilds the index text from a full-context patch", () => {
    const diff = fullContextDiff(
      [
        { line_type: "context", content: "a", old_line_number: 1, new_line_number: 1 },
        { line_type: "removed", content: "b", old_line_number: 2 },
        { line_type: "added", content: "B", new_line_number: 2 },
        { line_type: "context", content: "c", old_line_number: 3, new_line_number: 3 },
      ],
      "@@ -1,3 +1,3 @@",
    );
    expect(gitGutterBaseFromDiff(diff)).toEqual({ kind: "lines", lines: ["a", "b", "c"] });
  });

  test("treats an empty patch as unchanged and rejects partial or binary patches", () => {
    expect(gitGutterBaseFromDiff({ ...fullContextDiff([], "@@ -1 +1 @@"), lines: [] })).toEqual({
      kind: "unchanged",
    });
    const sparse = { ...fullContextDiff([], "@@ -10,2 +10,2 @@"), is_full_context: false };
    expect(gitGutterBaseFromDiff(sparse)).toBeNull();
    expect(gitGutterBaseFromDiff({ ...fullContextDiff([], "@@ -1 +1 @@"), is_binary: true })).toBeNull();
    expect(gitGutterBaseFromDiff(null)).toBeNull();
  });

  test("rejects a patch whose old side does not cover the whole index file", () => {
    const diff = fullContextDiff(
      [{ line_type: "context", content: "a", old_line_number: 1, new_line_number: 1 }],
      "@@ -1,2 +1,2 @@",
    );
    expect(gitGutterBaseFromDiff(diff)).toBeNull();
  });

  test("splits text like an editor, ignoring one trailing line break", () => {
    expect(splitGitGutterLines("a\r\nb\n")).toEqual(["a", "b"]);
    expect(splitGitGutterLines("a\rb")).toEqual(["a", "b"]);
    expect(splitGitGutterLines("")).toEqual([]);
  });
});

describe("Git gutter inline review rows", () => {
  test("shows the change with real line numbers and context up to the neighbours", () => {
    const base = ["a", "b", "c", "d", "e", "f"];
    const editor = ["a", "X", "c", "d", "e", "F"];
    const changes = changesOf(base, editor);
    const rows = gitGutterPeekRows(changes, 0, editor);

    expect(rows.map((row) => [row.kind, row.oldLine, row.newLine, row.left ?? row.right])).toEqual([
      ["context", 1, 1, "a"],
      ["removal", 2, null, "b"],
      ["addition", null, 2, "X"],
      ["context", 3, 3, "c"],
      ["context", 4, 4, "d"],
    ]);
    // The next change starts at editor line 6; its context stops before it.
    const next = gitGutterPeekRows(changes, 1, editor);
    expect(next.map((row) => row.newLine ?? row.oldLine)).toEqual([4, 5, 6, 6]);
  });

  test("keeps old line numbers aligned after an earlier insertion", () => {
    const base = ["a", "b", "c"];
    const editor = ["new", "a", "b", "C"];
    const changes = changesOf(base, editor);
    const rows = gitGutterPeekRows(changes, 1, editor);
    expect(rows.find((row) => row.kind === "context" && row.newLine === 3)?.oldLine).toBe(2);
  });
});

describe("Git gutter staging patch", () => {
  test("builds a hunk whose context comes from the index text", () => {
    const base = ["1", "2", "3", "4", "5", "6", "7", "8"];
    const [change] = changesOf(base, ["1", "2", "3", "4", "FIVE", "6", "7", "8"]);
    const hunk = gitGutterChangeHunk("src/app.ts", base, change);

    expect(hunk.file_path).toBe("src/app.ts");
    expect(hunk.lines.map((line) => `${line.line_type}:${line.content}`)).toEqual([
      "header:@@ -2,7 +2,7 @@",
      "context:2",
      "context:3",
      "context:4",
      "removed:5",
      "added:FIVE",
      "context:6",
      "context:7",
      "context:8",
    ]);
  });

  test("uses index context even when a neighbouring unstaged change is nearby", () => {
    // Line 2 and line 4 both changed; staging the second must not stage "B".
    const base = ["a", "b", "c", "d", "e"];
    const editor = ["a", "B", "c", "D", "e"];
    const changes = changesOf(base, editor);
    const hunk = gitGutterChangeHunk("f.txt", base, changes[1]);

    expect(hunk.lines.map((line) => `${line.line_type}:${line.content}`)).toEqual([
      "header:@@ -1,5 +1,5 @@",
      "context:a",
      "context:b",
      "context:c",
      "removed:d",
      "added:D",
      "context:e",
    ]);
  });

  test("names Git's empty ranges for an insertion at the start and a full deletion", () => {
    const [insertion] = changesOf([], ["x"]);
    expect(gitGutterChangeHunk("f", [], insertion).lines[0].content).toBe("@@ -0,0 +1,1 @@");

    const [deletion] = changesOf(["x"], []);
    expect(gitGutterChangeHunk("f", ["x"], deletion).lines[0].content).toBe("@@ -1,1 +0,0 @@");
  });
});


describe("Git gutter repository identity", () => {
  test("an untracked sibling path does not hide the tracked file's markers", () => {
    const files = [{
      path: "a/src/app.ts", repositoryPath: "C:/workspace/a",
      repositoryRelativePath: "src/app.ts", status: "untracked" as const, staged: false,
    }];
    expect(isGitGutterFileUntracked(files, "C:/workspace/b", "src/app.ts")).toBe(false);
    expect(isGitGutterFileUntracked(files, "C:/workspace/a/", "src/app.ts")).toBe(true);
    expect(isGitGutterFileUntracked(files, "C:/workspace/a", "src/other.ts")).toBe(false);
  });

  test("single-repository status retains undecorated path support", () => {
    expect(isGitGutterFileUntracked([
      { path: "src/app.ts", status: "untracked", staged: false },
    ], "C:/workspace/a", "src/app.ts")).toBe(true);
  });
});

describe("Git gutter isolated patch coordinates", () => {
  test("earlier unstaged deletions do not make the selected patch start negative", () => {
    const base = Array.from({ length: 10 }, (_, index) => String(index + 1));
    // Exercise an isolated range directly: Monaco may coalesce nearby edits,
    // but patch coordinates must remain valid for any selected range.
    const change: GitGutterChange = {
      kind: "modified", originalStart: 10, originalEnd: 11,
      modifiedStart: 2, modifiedEnd: 3, originalLines: ["10"], modifiedLines: ["TEN"],
    };
    const hunk = gitGutterChangeHunk("f", base, change);
    expect(hunk.lines[0].content).toBe("@@ -7,4 +7,4 @@");
    expect(hunk.lines.slice(1).map((line) => line.content)).toEqual(["7", "8", "9", "10", "TEN"]);
  });

  test("earlier unstaged insertions do not shift the selected patch", () => {
    const base = ["a", "b", "c", "d", "e", "f"];
    const changes = changesOf(base, ["new", ...base.slice(0, -1), "F"]);
    expect(changes).toHaveLength(2);
    expect(gitGutterChangeHunk("f", base, changes[1]).lines[0].content).toBe("@@ -3,4 +3,4 @@");
  });
});
