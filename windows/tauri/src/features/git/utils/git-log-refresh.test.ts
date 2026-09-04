import { describe, expect, test } from "bun:test";
import type { GitReference } from "../types/git.types";
import {
  loadGitHistoryWithReferenceFallback,
  selectedReferenceAfterRemoval,
  shouldRefreshGitLogForChange,
} from "./git-log-refresh";

describe("Git Log refresh events", () => {
  test("refreshes for history, refs, and repository changes", () => {
    const repoPath = "C:/work/project";

    expect(shouldRefreshGitLogForChange({ repoPath, scopes: ["history"] }, repoPath)).toBe(true);
    expect(shouldRefreshGitLogForChange({ repoPath, scopes: ["refs"] }, repoPath)).toBe(true);
    expect(shouldRefreshGitLogForChange({ repoPath, scopes: ["repository"] }, repoPath)).toBe(true);
  });

  test("ignores working-tree-only and unrelated repository changes", () => {
    const repoPath = "C:/work/project";

    expect(shouldRefreshGitLogForChange({ repoPath, scopes: ["working-tree"] }, repoPath)).toBe(
      false,
    );
    expect(
      shouldRefreshGitLogForChange(
        { repoPath: "C:/work/other", scopes: ["history"] },
        repoPath,
      ),
    ).toBe(false);
  });

  test("refreshes conservatively when an event has no scopes", () => {
    expect(shouldRefreshGitLogForChange({ repoPath: "C:/work/project" }, "C:/work/project")).toBe(
      true,
    );
  });

  test("clears a removed reference before the next history refresh", () => {
    const selectedReference: GitReference = {
      fullName: "refs/remotes/origin/feature/demo",
      shortName: "origin/feature/demo",
      kind: "remote",
      peelsToCommit: true,
      isCurrent: false,
    };

    expect(selectedReferenceAfterRemoval(selectedReference, selectedReference.fullName)).toBeNull();
    expect(selectedReferenceAfterRemoval(selectedReference, "refs/remotes/origin/main")).toBe(
      selectedReference,
    );
  });

  test("recovers a stale reference filter from the unfiltered history", async () => {
    const selectedReference: GitReference = {
      fullName: "refs/remotes/origin/feature/deleted",
      shortName: "origin/feature/deleted",
      kind: "remote",
      peelsToCommit: true,
      isCurrent: false,
    };
    const fallbackHistory = {
      references: [],
      recentReferences: [],
      commits: [],
      hasMore: false,
    };
    const requestedReferences: Array<string | undefined> = [];

    const result = await loadGitHistoryWithReferenceFallback(async (reference) => {
      requestedReferences.push(reference);
      return reference ? null : fallbackHistory;
    }, selectedReference);

    expect(requestedReferences).toEqual([selectedReference.fullName, undefined]);
    expect(result).toEqual({ history: fallbackHistory, reference: null });
  });
});
