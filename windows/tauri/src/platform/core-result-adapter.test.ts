import { describe, expect, test } from "bun:test";
import { adaptCoreResult } from "./core-result-adapter";
import type { GitBlame, GitDiff } from "@/features/git/types/git.types";
import { findGitBlameLine } from "@/features/git/utils/git-blame-lines";

test.each(["EOF", "CRLF", "LF"])("Core patch adaptation preserves writable safety metadata for %s", kind => {
  const separator = kind === "CRLF" ? "\r\n" : "\n";
  const patch = ["diff --git a/file.txt b/file.txt", "--- a/file.txt", "+++ b/file.txt",
    "@@ -1 +1 @@", "-a", "+B", ...(kind === "EOF" ? ["\\ No newline at end of file"] : []), ""].join(separator);
  const diff = adaptCoreResult<GitDiff>("git_diff_file", { filePath: "file.txt" }, { patch });
  expect(diff.has_lossy_line_endings === true).toBe(kind !== "LF");
  expect(diff.lines.map(line => line.content)).toEqual(["@@ -1 +1 @@", "a", "B"]);
});

describe("git status result adaptation", () => {
  test("keeps the file count of an untracked directory summary and its listing", () => {
    const summary = {
      path: "target/",
      status: "??",
      staged: false,
      worktree: false,
      untracked: true,
      canToggleStaging: true,
      untrackedFileCount: 5_273,
    };
    const adapted = {
      path: "target/",
      status: "untracked",
      staged: false,
      rawStatus: "??",
      canToggleStaging: true,
      worktree: false,
      untrackedFileCount: 5_273,
    };
    expect(
      adaptCoreResult<{ files: unknown[] }>("git_status", { repoPath: "C:/work" }, { changes: [summary] })
        .files,
    ).toEqual([adapted]);
    expect(
      adaptCoreResult<{ files: unknown[] }>(
        "git.untrackedDirectory",
        { repoPath: "C:/work" },
        { changes: [summary] },
      ),
    ).toEqual({ files: [adapted] });
  });

  test("preserves both paths of a renamed file", () => {
    const result = adaptCoreResult(
      "git_status",
      { repoPath: "C:/work" },
      {
        branch: "main",
        changes: [
          {
            path: "src/new-name.ts",
            originalPath: "src/old-name.ts",
            status: "R ",
            staged: true,
            worktree: false,
          },
        ],
      },
    );

    expect(result).toEqual({
      branch: "main",
      ahead: 0,
      behind: 0,
      files: [
        {
          path: "src/new-name.ts",
          originalPath: "src/old-name.ts",
          status: "renamed",
          staged: true,
          rawStatus: "R ",
          worktree: false,
        },
      ],
    });
  });

  test("maps whole-path status and removes snapshots that match HEAD", () => {
    const result = adaptCoreResult<{ files: Array<Record<string, unknown>> }>(
      "git_status",
      { repoPath: "C:/work" },
      {
        changes: [
          { path: "added.ts", status: "AM", staged: true, worktree: true },
          { path: "deleted.ts", status: "DM", staged: true, worktree: true },
          { path: "modified.ts", status: "MM", staged: true, worktree: true },
          { path: "no-op.ts", status: "AD", staged: true, worktree: true },
        ],
      },
    );

    expect(result.files.map((file) => [file.path, file.status])).toEqual([
      ["added.ts", "added"],
      ["deleted.ts", "deleted"],
      ["modified.ts", "modified"],
    ]);
  });
});

test("workspace status keeps index-only additions and Core submodule checkbox eligibility", () => {
  const submodule = { commitChanged: false, trackedChanges: true, untrackedChanges: false };
  const result = adaptCoreResult<{ files: Array<Record<string, unknown>> }>(
    "git_status",
    { includeIndexOnlyChanges: true },
    {
      changes: [
        {
          path: "staged-only.ts",
          status: "AD",
          staged: true,
          worktree: true,
          canToggleStaging: true,
        },
        {
          path: "libs/B",
          status: " M",
          staged: false,
          worktree: true,
          canToggleStaging: false,
          submodule,
        },
      ],
    },
  );
  expect(result.files[0]).toMatchObject({
    path: "staged-only.ts",
    staged: true,
    canToggleStaging: true,
  });
  expect(result.files[1]).toMatchObject({ path: "libs/B", canToggleStaging: false, submodule });
});

describe("git checkout result adaptation", () => {
  test("maps a successful core checkout to the UI checkout result", () => {
    const result = adaptCoreResult(
      "git_checkout",
      { repoPath: "C:/work", branchName: "main" },
      { output: "Switched to branch 'main'\n", exitCode: 0 },
    );

    expect(result).toEqual({
      success: true,
      hasChanges: false,
      message: "Switched to branch 'main'",
    });
  });

  test("reports failure when the core checkout exited non-zero", () => {
    const result = adaptCoreResult(
      "git_checkout",
      { repoPath: "C:/work", branchName: "main" },
      { output: "error: pathspec 'main' did not match", exitCode: 1 },
    );

    expect(result).toEqual({
      success: false,
      hasChanges: false,
      message: "error: pathspec 'main' did not match",
    });
  });

  test("keeps an empty message for a silent successful checkout", () => {
    const result = adaptCoreResult("git_checkout", undefined, { output: "", exitCode: 0 });

    expect(result).toEqual({ success: true, hasChanges: false, message: "" });
  });
});

describe("git repository discovery result adaptation", () => {
  test("accepts the read-only repository root string", () => {
    expect(adaptCoreResult<string>("git_discover_repo", { path: "C:/work/src" }, "C:/work\n")).toBe(
      "C:/work",
    );
  });

  test("keeps compatibility with the legacy command output envelope", () => {
    expect(
      adaptCoreResult<string>(
        "git_discover_repo",
        { path: "C:/work/src" },
        { output: "C:/work\n", exitCode: 0 },
      ),
    ).toBe("C:/work");
  });
});

describe("git tag checkout result adaptation", () => {
  test("maps a successful core tag checkout to the UI checkout result", () => {
    const result = adaptCoreResult(
      "git_checkout_tag",
      { repoPath: "C:/work", name: "v0.3.0" },
      { output: "HEAD is now at abc1234 Release 0.3.0\n", exitCode: 0 },
    );

    expect(result).toEqual({
      success: true,
      hasChanges: false,
      message: "HEAD is now at abc1234 Release 0.3.0",
    });
  });

  test("reports failure when the core tag checkout exited non-zero", () => {
    const result = adaptCoreResult(
      "git_checkout_tag",
      { repoPath: "C:/work", name: "missing-tag" },
      { output: "error: pathspec 'missing-tag' did not match", exitCode: 1 },
    );

    expect(result).toEqual({
      success: false,
      hasChanges: false,
      message: "error: pathspec 'missing-tag' did not match",
    });
  });
});

describe("git checkout preflight adaptation", () => {
  test("reports blocked paths returned by the shared core", () => {
    const result = adaptCoreResult(
      "git_checkout_preflight",
      { repoPath: "C:/work", branchName: "main" },
      { blockingPaths: ["src/main.rs", "README.md"] },
    );

    expect(result).toEqual({
      blocked: true,
      blockingPaths: ["src/main.rs", "README.md"],
    });
  });

  test("reports no blockage when the core returns no blocking paths", () => {
    const result = adaptCoreResult(
      "git_checkout_preflight",
      { repoPath: "C:/work", branchName: "main" },
      { blockingPaths: [] },
    );

    expect(result).toEqual({ blocked: false, blockingPaths: [] });
  });
});

describe("git blame adaptation", () => {
  const first = "1".repeat(40);
  const second = "2".repeat(40);
  const uncommitted = "0".repeat(40);

  test("attributes every Core line entry to a single-line span", () => {
    const blame = adaptCoreResult<GitBlame>(
      "git_blame_file",
      { filePath: "src/main.ts" },
      {
        lines: [
          { line: 1, commitHash: first, authorName: "Ada", authorTime: 1_700_000_000 },
          { line: 2, commitHash: second, authorName: "Lin", authorTime: 1_700_000_100 },
          { line: 3, commitHash: uncommitted, authorName: "Not Committed Yet", authorTime: 1_700_000_200 },
        ],
      },
    );

    expect(blame.file_path).toBe("src/main.ts");
    expect(blame.lines.map((line) => [line.line_number, line.total_lines, line.author])).toEqual([
      [1, 1, "Ada"],
      [2, 1, "Lin"],
      [3, 1, "Not Committed Yet"],
    ]);
    // A span covering the whole file makes the gutter lookup match the wrong
    // commit for almost every line, which is what the editor used to show.
    expect(findGitBlameLine(blame.lines, 2)?.commit_hash).toBe(second);
    expect(blame.lines[2].is_uncommitted).toBe(true);
  });
});
