import { expect, test } from "bun:test";
import type { GitFile } from "../types/git.types";
import { DEFAULT_CHANGELIST, changelistPathKey } from "./git-changelists";
import { orderGitStatusFilesForDisplay } from "./git-status-display-order";

const file = (
  path: string,
  status: GitFile["status"],
  extra: Partial<GitFile> = {},
): GitFile => ({ path, status, staged: false, worktree: true, ...extra });

test("flat view follows IDEA status groups instead of raw path order", () => {
  // Core sorts by path, so the untracked chairman file sits between both
  // modified files; the Commit panel renders modified rows first.
  const files = [
    file(".agents/SKILL.md", "modified"),
    file("backend/app/api/chairman.py", "untracked"),
    file("backend/app/core/org.py", "modified"),
  ];
  expect(
    orderGitStatusFilesForDisplay(files, { repoPath: "C:/repo", folderView: false }).map(
      (entry) => entry.path,
    ),
  ).toEqual([".agents/SKILL.md", "backend/app/core/org.py", "backend/app/api/chairman.py"]);
});

test("folder view follows the Git folder tree and skips directory summaries", () => {
  const files = [
    file(".agents/SKILL.md", "modified"),
    file("backend/app/api/chairman.py", "untracked"),
    file("backend/app/core/org.py", "modified"),
    file("frontend/src/views/dashboard/", "untracked", { untrackedFileCount: 11 }),
  ];
  expect(
    orderGitStatusFilesForDisplay(files, { repoPath: "C:/repo", folderView: true }).map(
      (entry) => entry.path,
    ),
  ).toEqual([".agents/SKILL.md", "backend/app/api/chairman.py", "backend/app/core/org.py"]);
});

test("changelist assignment splits the order exactly like the panel sections", () => {
  const files = [file("a.py", "modified"), file("b.py", "modified"), file("c.py", "modified")];
  const changelists = {
    lists: [
      { id: DEFAULT_CHANGELIST, name: "" },
      { id: "wip", name: "WIP" },
    ],
    activeId: DEFAULT_CHANGELIST,
    assignments: { [changelistPathKey("C:/repo", "b.py")]: "wip" },
  };
  expect(
    orderGitStatusFilesForDisplay(files, {
      repoPath: "C:/repo",
      changelists,
      folderView: false,
    }).map((entry) => entry.path),
  ).toEqual(["a.py", "c.py", "b.py"]);
});

test("repository groups keep their first-seen order", () => {
  const files = [
    file("nested/b.txt", "modified", { repositoryPath: "C:/repo/nested", repositoryRelativePath: "b.txt" }),
    file("a.txt", "modified"),
  ];
  expect(
    orderGitStatusFilesForDisplay(files, { repoPath: "C:/repo", folderView: false }).map(
      (entry) => `${entry.repositoryPath ?? "C:/repo"}/${entry.repositoryRelativePath ?? entry.path}`,
    ),
  ).toEqual(["C:/repo/nested/b.txt", "C:/repo/a.txt"]);
});
