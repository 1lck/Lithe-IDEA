import { expect, test } from "bun:test";
import type { GitCommit, GitReference } from "../types/git.types";
import { currentGitBranchHashes, shouldHighlightCurrentGitBranch } from "./git-graph-highlights";
const commit = (hash: string, parentHashes: string[] = [], decorations = ""): GitCommit => ({
  hash,
  shortHash: hash,
  parentHashes,
  decorations,
  message: hash,
  author: "Fixture",
  date: "unknown",
});
const branch: GitReference = {
  fullName: "refs/heads/main",
  shortName: "main",
  kind: "local",
  isCurrent: true,
  peelsToCommit: true,
};
test("current-branch membership crosses both merge parents through the repository context", () => {
  const scope = [commit("feature", ["base"], "feature")];
  const context = [
    commit("main", ["a", "b"], "HEAD -> main"),
    commit("a", ["base"]),
    commit("b", ["base"]),
    commit("base"),
  ];
  expect([...currentGitBranchHashes(scope, context, [branch])].sort()).toEqual([
    "a",
    "b",
    "base",
    "main",
  ]);
});
test("missing branch identities do not guess membership and cycles remain bounded", () => {
  expect(currentGitBranchHashes([commit("head", [], "HEAD")], [], []).size).toBe(0);
  expect(currentGitBranchHashes([commit("head")], [], [branch]).size).toBe(0);
  const values = [commit("a", ["b"], "main"), commit("b", ["a"])];
  expect([...currentGitBranchHashes(values, [], [branch])].sort()).toEqual(["a", "b"]);
});
test("visible commits win over stale duplicate context and pagination extends ancestry", () => {
  const scope = [commit("main", ["new"], "main")];
  const context = [commit("main", ["stale"], "main"), commit("new", ["root"]), commit("root")];
  expect([...currentGitBranchHashes(scope, context, [branch])].sort()).toEqual([
    "main",
    "new",
    "root",
  ]);
});
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
