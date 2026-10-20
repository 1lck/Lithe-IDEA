import { expect, test } from "bun:test";
import type { GitReference } from "../types/git.types";
import { groupGitLogBranchFilterReferences } from "./git-log-branch-filter";

const reference = (fullName: string, kind: GitReference["kind"]): GitReference => ({
  fullName,
  shortName: fullName.replace(/^refs\/(heads|remotes|tags)\//, ""),
  kind,
  peelsToCommit: true,
  isCurrent: false,
});

test("groups references as Local then one group per remote, in natural order, without tags", () => {
  const groups = groupGitLogBranchFilterReferences([
    reference("refs/tags/v1", "tag"),
    reference("refs/remotes/upstream/main", "remote"),
    reference("refs/remotes/origin/main", "remote"),
    reference("refs/remotes/origin/HEAD", "remote"),
    reference("refs/heads/feature-10", "local"),
    reference("refs/heads/feature-2", "local"),
  ]);
  expect(groups.map((group) => group.id)).toEqual([
    "local",
    "remote:origin",
    "remote:upstream",
  ]);
  expect(groups[0].references.map((value) => value.shortName)).toEqual([
    "feature-2",
    "feature-10",
  ]);
  // The remote symbolic HEAD pointer is not a branch the user can filter by.
  expect(groups[1].references.map((value) => value.shortName)).toEqual(["origin/main"]);
});

test("omits empty groups", () => {
  expect(groupGitLogBranchFilterReferences([])).toEqual([]);
  expect(
    groupGitLogBranchFilterReferences([reference("refs/heads/main", "local")]).map(
      (group) => group.id,
    ),
  ).toEqual(["local"]);
});
