import { describe, expect, test } from "bun:test";
import type { GitReference } from "../types/git.types";
import {
  reconcileGitLogReference,
  selectedReferenceAfterRemoval,
  selectedReferenceAfterRename,
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
      shouldRefreshGitLogForChange({ repoPath: "C:/work/other", scopes: ["history"] }, repoPath),
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

  test("rebinds a selected reference to its renamed identity", () => {
    const selectedReference: GitReference = {
      fullName: "refs/heads/feature/old-name",
      shortName: "feature/old-name",
      kind: "local",
      peelsToCommit: true,
      isCurrent: false,
      upstreamShortName: "origin/feature/old-name",
      ahead: 1,
      behind: 0,
    };
    const renamedReference: GitReference = {
      ...selectedReference,
      fullName: "refs/heads/feature/new-name",
      shortName: "feature/new-name",
    };

    expect(
      selectedReferenceAfterRename(selectedReference, selectedReference.fullName, renamedReference),
    ).toBe(renamedReference);
    expect(
      selectedReferenceAfterRename(
        { ...selectedReference, fullName: "refs/heads/other" },
        selectedReference.fullName,
        renamedReference,
      ),
    ).not.toBe(renamedReference);
  });

  test("rebinds the selected reference to refreshed metadata", () => {
    const selectedReference: GitReference = {
      fullName: "refs/heads/main",
      shortName: "main",
      kind: "local",
      peelsToCommit: true,
      isCurrent: false,
      upstreamShortName: "origin/main",
      behind: 2,
    };
    const refreshedReference: GitReference = {
      ...selectedReference,
      isCurrent: true,
      behind: 0,
    };

    const result = reconcileGitLogReference(selectedReference, [refreshedReference]);

    expect(result).toEqual({ reference: refreshedReference, isMissing: false });
    expect(result.reference).toBe(refreshedReference);
  });

  test("only treats a selected reference as missing after a fresh reference snapshot", () => {
    const selectedReference: GitReference = {
      fullName: "refs/remotes/origin/feature/deleted",
      shortName: "origin/feature/deleted",
      kind: "remote",
      peelsToCommit: true,
      isCurrent: false,
    };

    expect(reconcileGitLogReference(selectedReference, null)).toEqual({
      reference: selectedReference,
      isMissing: false,
    });
    expect(reconcileGitLogReference(selectedReference, [])).toEqual({
      reference: null,
      isMissing: true,
    });
  });
});
