import { describe, expect, test } from "bun:test";
import { adaptCoreResult } from "./core-result-adapter";

describe("git operation state adaptation", () => {
  test("maps an in-progress rebase with progress counters", () => {
    const state = adaptCoreResult(
      "git_operation_state",
      { repoPath: "C:/work" },
      {
        kind: "rebase",
        reference: "abc123",
        step: 3,
        total: 7,
        conflictedPaths: ["src/main.rs", "README.md"],
      },
    );

    expect(state).toEqual({
      kind: "rebase",
      reference: "abc123",
      step: 3,
      total: 7,
      conflictedPaths: ["src/main.rs", "README.md"],
    });
  });

  test("returns null when no operation is in progress", () => {
    const state = adaptCoreResult(
      "git_operation_state",
      { repoPath: "C:/work" },
      { kind: "", reference: null, step: null, total: null, conflictedPaths: [] },
    );

    expect(state).toBeNull();
  });

  test("keeps merge state without optional counters", () => {
    const state = adaptCoreResult(
      "git_operation_state",
      { repoPath: "C:/work" },
      { kind: "merge", reference: null, step: null, total: null, conflictedPaths: ["a.txt"] },
    );

    expect(state).toEqual({
      kind: "merge",
      reference: null,
      step: null,
      total: null,
      conflictedPaths: ["a.txt"],
    });
  });
});

describe("git integration preflight adaptation", () => {
  test("passes through blocking paths and the blocks-entirely flag", () => {
    const preflight = adaptCoreResult(
      "git_integration_preflight",
      { repoPath: "C:/work", branchName: "main", operation: "rebase" },
      { blockingPaths: ["a.txt", "b.txt"], blocksEntirely: true },
    );

    expect(preflight).toEqual({
      blockingPaths: ["a.txt", "b.txt"],
      blocksEntirely: true,
    });
  });
});

describe("git conflict marker adaptation", () => {
  test("passes through staged files that still contain markers", () => {
    const markers = adaptCoreResult(
      "git_conflict_markers",
      { repoPath: "C:/work" },
      { paths: ["src/conflicted.rs"] },
    );

    expect(markers).toEqual({ paths: ["src/conflicted.rs"] });
  });
});
