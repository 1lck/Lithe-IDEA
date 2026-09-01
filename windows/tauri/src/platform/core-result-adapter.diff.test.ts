import { describe, expect, test } from "bun:test";
import type { GitDiff } from "@/features/git/types/git.types";
import { adaptCoreResult } from "./core-result-adapter";

const twoFilePatch = `diff --git a/a.txt b/a.txt
index 111..222 100644
--- a/a.txt
+++ b/a.txt
@@ -1 +1,2 @@
 hello
+world
diff --git a/b.txt b/b.txt
index 333..444 100644
--- a/b.txt
+++ b/b.txt
@@ -1 +0,0 @@
-old line
`;

describe("git diff stats adaptation", () => {
  test("maps Core numstat entries without parsing a patch", () => {
    const stats = adaptCoreResult(
      "git_status_diff_stats",
      { repoPath: "C:/work" },
      {
        files: [
          { path: "a.txt", staged: false, additions: 1, deletions: 0, binary: false },
          { path: "b.txt", staged: false, additions: 0, deletions: 1, binary: false },
        ],
        additions: 1,
        deletions: 1,
      },
    );

    expect(stats).toEqual([
      { file_path: "a.txt", staged: false, additions: 1, deletions: 0 },
      { file_path: "b.txt", staged: false, additions: 0, deletions: 1 },
    ]);
  });

  test("carries the staged flag from the request into every stat entry", () => {
    const stats = adaptCoreResult(
      "git_status_diff_stats",
      { repoPath: "C:/work", staged: true },
      {
        files: [
          { path: "a.txt", additions: 1, deletions: 0, binary: false },
          { path: "b.txt", additions: 0, deletions: 1, binary: false },
        ],
      },
    );

    expect(Array.isArray(stats)).toBe(true);
    for (const stat of stats as Array<{ staged: boolean }>) {
      expect(stat.staged).toBe(true);
    }
  });

  test("keeps accepting the legacy patch response during Core upgrades", () => {
    const stats = adaptCoreResult(
      "git_status_diff_stats",
      { repoPath: "C:/work" },
      { patch: twoFilePatch },
    );

    expect(stats).toEqual([
      { file_path: "a.txt", staged: false, additions: 1, deletions: 0 },
      { file_path: "b.txt", staged: false, additions: 0, deletions: 1 },
    ]);
  });
});

describe("git single-file diff adaptation", () => {
  test("returns the parsed diff for the requested file", () => {
    const diff = adaptCoreResult(
      "git_diff_file",
      { repoPath: "C:/work", filePath: "a.txt" },
      { patch: twoFilePatch },
    );

    expect((diff as { file_path: string }).file_path).toBe("a.txt");
  });

  test("preserves Core's aligned rows for the split viewer", () => {
    const patch = `diff --git a/a.txt b/a.txt
--- a/a.txt
+++ b/a.txt
@@ -1,2 +1,3 @@
 a
-aa
\\ No newline at end of file
+aa
+abc
\\ No newline at end of file
`;
    const diff = adaptCoreResult(
      "git_diff_file",
      { repoPath: "C:/work", filePath: "a.txt" },
      {
        patch,
        rows: [
          { kind: "information", left: "@@ -1,2 +1,3 @@", hunkId: "hunk-0" },
          { kind: "context", oldLine: 1, newLine: 1, left: "a", hunkId: "hunk-0" },
          { kind: "changed", oldLine: 2, newLine: 2, left: "aa", right: "aa", hunkId: "hunk-0" },
          { kind: "addition", newLine: 3, right: "abc", hunkId: "hunk-0" },
        ],
      },
    ) as GitDiff;

    expect(diff.split_hunks).toEqual([
      [
        {
          kind: "context",
          old_line_number: 1,
          new_line_number: 1,
          old_content: "a",
          new_content: "a",
        },
        {
          kind: "context",
          old_line_number: 2,
          new_line_number: 2,
          old_content: "aa",
          new_content: "aa",
          is_invisible_change: true,
        },
        {
          kind: "addition",
          old_line_number: undefined,
          new_line_number: 3,
          old_content: undefined,
          new_content: "abc",
        },
      ],
    ]);
    expect({ additions: diff.additions, deletions: diff.deletions }).toEqual({
      additions: 1,
      deletions: 0,
    });
    expect(diff.lines.some((line) => line.content.includes("No newline"))).toBe(false);
  });

  test("marks carriage-return-only rows as invisible line-ending changes", () => {
    const patch = `diff --git a/a.txt b/a.txt
--- a/a.txt
+++ b/a.txt
@@ -1 +1 @@
-same
+same
`;
    const diff = adaptCoreResult(
      "git_diff_file",
      { repoPath: "C:/work", filePath: "a.txt" },
      {
        patch,
        rows: [
          { kind: "information", left: "@@ -1 +1 @@", hunkId: "hunk-0" },
          {
            kind: "changed",
            oldLine: 1,
            newLine: 1,
            left: "same",
            right: "same\r",
            hunkId: "hunk-0",
          },
        ],
      },
    ) as GitDiff;

    expect(diff.split_hunks).toEqual([
      [
        {
          kind: "context",
          old_line_number: 1,
          new_line_number: 1,
          old_content: "same",
          new_content: "same\r",
          is_invisible_change: true,
        },
      ],
    ]);
    expect({ additions: diff.additions, deletions: diff.deletions }).toEqual({
      additions: 0,
      deletions: 0,
    });
  });

  test("uses semantic stats when an unchanged EOF line is paired", () => {
    const patch = `diff --git a/a.txt b/a.txt
--- a/a.txt
+++ b/a.txt
@@ -1,2 +1,3 @@
 a
-aa
\\ No newline at end of file
+aa
+abc
\\ No newline at end of file
`;
    const stats = adaptCoreResult(
      "git_status_diff_stats",
      { repoPath: "C:/work" },
      {
        patch,
        rows: [
          { kind: "information", left: "@@ -1,2 +1,3 @@", hunkId: "hunk-0" },
          { kind: "context", oldLine: 1, newLine: 1, left: "a", hunkId: "hunk-0" },
          { kind: "changed", oldLine: 2, newLine: 2, left: "aa", right: "aa", hunkId: "hunk-0" },
          { kind: "addition", newLine: 3, right: "abc", hunkId: "hunk-0" },
        ],
      },
    );

    expect(stats).toEqual([
      { file_path: "a.txt", staged: false, additions: 1, deletions: 0 },
    ]);
  });

  test("adapts an untracked file through the shared Core diff contract", () => {
    const diff = adaptCoreResult(
      "git_diff_file",
      { repoPath: "C:/work", filePath: "new.txt", untracked: true },
      {
        patch: `diff --git a/new.txt b/new.txt
new file mode 100644
index 0000000..1234567
--- /dev/null
+++ b/new.txt
@@ -0,0 +1,2 @@
+first
+second
`,
        rows: [
          { kind: "information", left: "@@ -0,0 +1,2 @@", hunkId: "hunk-0" },
          { kind: "addition", newLine: 1, right: "first", hunkId: "hunk-0" },
          { kind: "addition", newLine: 2, right: "second", hunkId: "hunk-0" },
        ],
      },
    ) as GitDiff;

    expect(diff.is_new).toBe(true);
    expect({ additions: diff.additions, deletions: diff.deletions }).toEqual({
      additions: 2,
      deletions: 0,
    });
  });

  test("keeps untracked binary files out of the text renderer", () => {
    const diff = adaptCoreResult(
      "git_diff_file",
      { repoPath: "C:/work", filePath: "image.png", untracked: true },
      {
        patch: `diff --git a/image.png b/image.png
new file mode 100644
index 0000000..1234567
Binary files /dev/null and b/image.png differ
`,
      },
    ) as GitDiff;

    expect(diff.is_new).toBe(true);
    expect(diff.is_binary).toBe(true);
    expect(diff.lines).toEqual([]);
  });
});
