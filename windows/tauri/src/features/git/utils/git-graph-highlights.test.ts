import { expect, test } from "bun:test";
import type { GitReference } from "../types/git.types";
import { shouldHighlightCurrentGitBranch } from "./git-graph-highlights";

// Current-branch ancestry itself is Core's (`git.graphProjection` currentBranchHashes).
const branch: GitReference = {
  fullName: "refs/heads/main",
  shortName: "main",
  kind: "local",
  isCurrent: true,
  peelsToCommit: true,
};
test("all references and other branches highlight while current branch and HEAD views do not", () => {
  expect(shouldHighlightCurrentGitBranch(null)).toBe(true);
  expect(shouldHighlightCurrentGitBranch(branch)).toBe(false);
  expect(shouldHighlightCurrentGitBranch({ ...branch, isCurrent: false, shortName: "HEAD" })).toBe(
    false,
  );
  expect(
    shouldHighlightCurrentGitBranch({ ...branch, isCurrent: false, shortName: "feature" }),
  ).toBe(true);
});
