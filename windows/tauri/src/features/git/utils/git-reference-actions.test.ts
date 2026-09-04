import { describe, expect, test } from "bun:test";
import type { GitReference } from "../types/git.types";
import {
  getGitReferenceActions,
  getGitReferenceToolbarState,
  suggestWorktreeBranchName,
} from "./git-reference-actions";

const reference = (
  kind: GitReference["kind"],
  shortName: string,
  isCurrent = false,
): GitReference => ({
  fullName:
    kind === "local"
      ? `refs/heads/${shortName}`
      : kind === "remote"
        ? `refs/remotes/${shortName}`
        : `refs/tags/${shortName}`,
  shortName,
  kind,
  peelsToCommit: true,
  isCurrent,
});

describe("Git reference actions", () => {
  test("gives the current branch update, tracking, push, and rename actions", () => {
    expect(getGitReferenceActions(reference("local", "main", true))).toEqual([
      "createBranch",
      "diffWithWorkingTree",
      "createWorktree",
      "update",
      "push",
      "tracking",
      "rename",
    ]);
  });

  test("gives another local branch checkout, integration, and delete actions", () => {
    const actions = getGitReferenceActions(reference("local", "feature/orders"));
    expect(actions).toContain("checkout");
    expect(actions).toContain("checkoutAndRebase");
    expect(actions).toContain("checkoutAndUpdate");
    expect(actions).toContain("rebaseCurrentOnto");
    expect(actions).toContain("mergeIntoCurrent");
    expect(actions).toContain("deleteLocal");
    expect(actions).toContain("update");
  });

  test("gives remote branches integration and remote deletion without local rename", () => {
    const actions = getGitReferenceActions(reference("remote", "origin/feature/orders"));
    expect(actions).toContain("checkout");
    expect(actions).toContain("createBranch");
    expect(actions).toContain("pullRebaseIntoCurrent");
    expect(actions).toContain("pullMergeIntoCurrent");
    expect(actions).toContain("deleteRemote");
    expect(actions).not.toContain("rename");
  });

  test("suggests a safe display-derived worktree branch without parsing remote identity", () => {
    const remote = reference("remote", "team/origin/feature/orders");
    expect(suggestWorktreeBranchName(remote)).toBe("orders-worktree");
  });

  test("offers only checkout, branch creation, and comparisons for tags", () => {
    expect(getGitReferenceActions(reference("tag", "v1.0.0"))).toEqual([
      "checkout",
      "createBranch",
      "compareWithCurrent",
      "diffWithWorkingTree",
    ]);
  });

  test("enables toolbar mutations only for applicable selected references", () => {
    const current = {
      ...reference("local", "main", true),
      upstreamShortName: "origin/main",
    };
    const behind = {
      ...reference("local", "release"),
      upstreamShortName: "origin/release",
      behind: 3,
    };

    expect(getGitReferenceToolbarState(current, current, false)).toMatchObject({
      canCreateBranch: true,
      canUpdateSelected: true,
      canDeleteBranch: false,
      canCompareWithCurrent: false,
    });
    expect(getGitReferenceToolbarState(behind, current, false)).toMatchObject({
      canUpdateSelected: true,
      canDeleteBranch: true,
      canCompareWithCurrent: true,
    });
    expect(
      getGitReferenceToolbarState(reference("local", "feature"), current, false),
    ).toMatchObject({
      canUpdateSelected: false,
      canDeleteBranch: true,
      canCompareWithCurrent: true,
    });
    expect(getGitReferenceToolbarState(behind, current, true)).toMatchObject({
      canCreateBranch: false,
      canUpdateSelected: false,
      canDeleteBranch: false,
      canCompareWithCurrent: false,
      canFetch: false,
      canToggleMark: true,
    });
    expect(
      getGitReferenceToolbarState(reference("remote", "origin/main"), current, false),
    ).toMatchObject({
      canToggleMark: false,
    });
    expect(getGitReferenceToolbarState(reference("tag", "v1.0.0"), current, false)).toMatchObject({
      canToggleMark: false,
    });
  });
});
