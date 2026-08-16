import { describe, expect, test } from "bun:test";
import { adaptCoreResult } from "./core-result-adapter";

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
