import { describe, expect, test } from "bun:test";
import type { GitReference } from "../../types/git.types";
import { getGitReferenceActions } from "./git-reference-tree";

const reference = (
  kind: GitReference["kind"],
  isCurrent = false,
): GitReference => ({
  fullName:
    kind === "local"
      ? "refs/heads/main"
      : kind === "remote"
        ? "refs/remotes/origin/feature"
        : "refs/tags/v1.0.0",
  shortName: kind === "remote" ? "origin/feature" : kind === "tag" ? "v1.0.0" : "main",
  kind,
  isCurrent,
});

describe("Git reference context actions", () => {
  test("offers remote integration and pull actions", () => {
    expect(getGitReferenceActions(reference("remote"))).toEqual([
      "checkout",
      "createBranch",
      "showWorkingTreeDiff",
      "compareWithCurrent",
      "checkoutAndRebase",
      "rebaseCurrent",
      "mergeCurrent",
      "pullRebase",
      "pullMerge",
    ]);
  });

  test("keeps tags to applicable non-integration actions", () => {
    expect(getGitReferenceActions(reference("tag"))).toEqual([
      "checkout",
      "createBranch",
      "showWorkingTreeDiff",
      "compareWithCurrent",
    ]);
  });

  test("does not offer self operations for the current branch", () => {
    expect(getGitReferenceActions(reference("local", true))).toEqual([
      "createBranch",
      "showWorkingTreeDiff",
    ]);
  });
});
