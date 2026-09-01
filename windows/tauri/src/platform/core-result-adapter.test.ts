import { describe, expect, test } from "bun:test";
import { adaptCoreResult } from "./core-result-adapter";

describe("git status result adaptation", () => {
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
