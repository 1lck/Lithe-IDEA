import { describe, expect, test } from "bun:test";
import type { GitDiff, GitFile } from "@/features/git/types/git.types";
import {
  buildGitFileContextMenuItems,
  buildWorkingTreeDiffTarget,
  findGitStatusFileForPath,
  getExplorerGitFileMenuCapabilities,
  hasGitDiffContent,
  isVirtualWorkspacePath,
  type ExplorerGitFileMenuCapabilities,
} from "./file-context-menu-git-file-items";

const noOpAction = () => {};

function buildItems(capabilities: ExplorerGitFileMenuCapabilities) {
  return buildGitFileContextMenuItems({
    labels: {
      submenu: "Git",
      showDiff: "Show Diff",
      add: "Add",
      commitFile: "Commit File…",
    },
    actions: {
      showDiff: noOpAction,
      add: noOpAction,
      commitFile: noOpAction,
    },
    capabilities,
  });
}

function makeDiff(overrides: Partial<GitDiff> = {}): GitDiff {
  return {
    file_path: "src/App.java",
    is_new: false,
    is_deleted: false,
    is_renamed: false,
    lines: [],
    ...overrides,
  };
}

function makeGitFile(overrides: Partial<GitFile> = {}): GitFile {
  return {
    path: "src/App.java",
    status: "modified",
    staged: false,
    ...overrides,
  };
}

describe("getExplorerGitFileMenuCapabilities", () => {
  test("returns no capabilities without a Git change entry", () => {
    expect(getExplorerGitFileMenuCapabilities(null)).toEqual({
      showDiff: false,
      add: false,
      commitFile: false,
    });
  });

  test("untracked files can be diffed, added and committed", () => {
    expect(getExplorerGitFileMenuCapabilities({ status: "untracked", staged: false })).toEqual({
      showDiff: true,
      add: true,
      commitFile: true,
    });
  });

  test("unstaged modifications keep the add action", () => {
    expect(getExplorerGitFileMenuCapabilities({ status: "modified", staged: false }).add).toBe(
      true,
    );
  });

  test("staged entries hide the add action because staging again is a no-op", () => {
    expect(getExplorerGitFileMenuCapabilities({ status: "modified", staged: true }).add).toBe(
      false,
    );
    expect(getExplorerGitFileMenuCapabilities({ status: "added", staged: true }).add).toBe(false);
  });

  test("deleted and renamed entries still support diff and commit", () => {
    expect(getExplorerGitFileMenuCapabilities({ status: "deleted", staged: false })).toEqual({
      showDiff: true,
      add: true,
      commitFile: true,
    });
    expect(getExplorerGitFileMenuCapabilities({ status: "renamed", staged: true }).showDiff).toBe(
      true,
    );
  });
});

describe("buildGitFileContextMenuItems", () => {
  test("renders a Git submenu with every enabled action", () => {
    const items = buildItems({ showDiff: true, add: true, commitFile: true });

    expect(items).toHaveLength(1);
    expect(items[0].id).toBe("git-file");
    expect(items[0].children?.map((child) => child.id)).toEqual([
      "git-show-diff",
      "git-add",
      "git-commit-file",
    ]);
  });

  test("omits disabled actions from the submenu", () => {
    const items = buildItems({ showDiff: true, add: false, commitFile: true });

    expect(items[0].children?.map((child) => child.id)).toEqual([
      "git-show-diff",
      "git-commit-file",
    ]);
  });

  test("returns no submenu when no capability applies", () => {
    expect(buildItems({ showDiff: false, add: false, commitFile: false })).toEqual([]);
  });
});

describe("hasGitDiffContent", () => {
  test("null and empty text diffs have no content", () => {
    expect(hasGitDiffContent(null)).toBe(false);
    expect(hasGitDiffContent(makeDiff())).toBe(false);
  });

  test("diffs with rows, image or binary payloads have content", () => {
    expect(hasGitDiffContent(makeDiff({ lines: [{} as GitDiff["lines"][number]] }))).toBe(true);
    expect(hasGitDiffContent(makeDiff({ is_image: true }))).toBe(true);
    expect(hasGitDiffContent(makeDiff({ is_binary: true }))).toBe(true);
  });
});

describe("buildWorkingTreeDiffTarget", () => {
  test("carries the owning repository so refreshes never guess the workspace root", () => {
    const { target, fileKey } = buildWorkingTreeDiffTarget(
      { repoPath: "C:/work/repo-b", repositoryRelativePath: "src/App.java", status: "modified" },
      false,
    );

    expect(target).toEqual({
      repoPath: "C:/work/repo-b",
      filePath: "src/App.java",
      untracked: false,
    });
    expect(fileKey).toBe("unstaged:src/App.java");
  });

  test("marks staged view and the file key accordingly", () => {
    const { target, fileKey } = buildWorkingTreeDiffTarget(
      { repoPath: "C:/work/repo-b", repositoryRelativePath: "src/App.java", status: "modified" },
      true,
    );

    expect(target.staged).toBe(true);
    expect(fileKey).toBe("staged:src/App.java");
  });

  test("propagates untracked status and rename original path when present", () => {
    const untracked = buildWorkingTreeDiffTarget(
      { repoPath: "R", repositoryRelativePath: "New.txt", status: "untracked" },
      false,
    );
    expect(untracked.target.untracked).toBe(true);

    const renamed = buildWorkingTreeDiffTarget(
      {
        repoPath: "R",
        repositoryRelativePath: "New.txt",
        originalPath: "Old.txt",
        status: "renamed",
      },
      false,
    );
    expect(renamed.target.originalPath).toBe("Old.txt");
    expect(renamed.target.untracked).toBe(false);
  });

  test("omits optional fields instead of emitting undefined entries", () => {
    const { target } = buildWorkingTreeDiffTarget(
      { repoPath: "R", repositoryRelativePath: "A.java", status: "modified" },
      false,
    );

    expect("originalPath" in target).toBe(false);
    expect("staged" in target).toBe(false);
  });
});

describe("findGitStatusFileForPath", () => {
  test("prefers repositoryRelativePath over the workspace-decorated path", () => {
    const file = makeGitFile({
      path: "repo-a :: src/App.java",
      repositoryPath: "C:/work/repo-a",
      repositoryRelativePath: "src/App.java",
    });

    const match = findGitStatusFileForPath([file], "src/App.java");

    expect(match?.file).toBe(file);
    expect(match?.repositoryRelativePath).toBe("src/App.java");
  });

  test("falls back to the plain path when no repository decoration exists", () => {
    const match = findGitStatusFileForPath([makeGitFile()], "src/App.java");

    expect(match?.file.path).toBe("src/App.java");
  });

  test("normalizes Windows separators on both sides", () => {
    const file = makeGitFile({ path: "src\\nested\\App.java" });

    expect(findGitStatusFileForPath([file], "src/nested/App.java")?.repositoryRelativePath).toBe(
      "src/nested/App.java",
    );
  });

  test("returns null when the file has no change entry", () => {
    expect(findGitStatusFileForPath([makeGitFile()], "src/Other.java")).toBeNull();
    expect(findGitStatusFileForPath([], "src/App.java")).toBeNull();
  });
});

describe("isVirtualWorkspacePath", () => {
  test("recognizes virtual buffer namespaces", () => {
    expect(isVirtualWorkspacePath("remote://host/workspace")).toBe(true);
    expect(isVirtualWorkspacePath("wsl://Ubuntu/home/dev")).toBe(true);
    expect(isVirtualWorkspacePath("diff://unstaged/src%2FApp.java")).toBe(true);
  });

  test("accepts real workspace paths", () => {
    expect(isVirtualWorkspacePath("C:/work/project/pom.xml")).toBe(false);
    expect(isVirtualWorkspacePath("/home/dev/project/pom.xml")).toBe(false);
  });
});
