import { describe, expect, test } from "bun:test";
import {
  createFileTreeGitStatusLookup,
  getFileTreeEntryGitStatusDecoration,
} from "@/features/file-explorer/lib/file-tree-git-status";
import { countUniqueGitChanges } from "@/features/layout/utils/footer-status";
import type { GitFile } from "../types/git.types";
import {
  changelistFileKey,
  DEFAULT_CHANGELIST,
  EMPTY_CHANGELISTS,
  fileChangelist,
  type LocalChangelists,
} from "./git-changelists";
import { isGitGutterFileUntracked } from "./git-gutter-changes";
import { resolveGitStatusDeletionPaths } from "./git-status-selection";
import {
  countGitChangedFiles,
  findContainingUntrackedDirectory,
  withoutListedUntrackedContents,
} from "./git-untracked-directories";

// Regression coverage for #1385: a large untracked directory is one `dir/`
// summary, and every consumer must treat it as the files it stands for.
const untracked = (path: string, untrackedFileCount?: number, repository?: string): GitFile => ({
  path: repository ? `${repository}/${path}` : path,
  ...(repository
    ? { repositoryPath: `C:/workspace/${repository}`, repositoryRelativePath: path }
    : {}),
  status: "untracked",
  staged: false,
  canToggleStaging: true,
  ...(untrackedFileCount === undefined ? {} : { untrackedFileCount }),
});
const modified = (path: string, staged = false): GitFile => ({
  path,
  status: "modified",
  staged,
});

describe("untracked directory summaries", () => {
  const expanded = [
    modified("src/App.tsx"),
    untracked("target/", 5_273),
    untracked("target/.rustc_info.json"),
    untracked("target/debug/", 5_272),
  ];

  test("count the files a summary stands for once, including while it is expanded", () => {
    expect(countGitChangedFiles([modified("src/App.tsx"), untracked("target/", 5_273)])).toBe(
      5_274,
    );
    expect(countGitChangedFiles(expanded)).toBe(5_274);
    expect(countUniqueGitChanges(expanded)).toBe(5_274);
    expect(countUniqueGitChanges(undefined)).toBe(0);
  });

  test("drop listed contents covered by a summary in the same set", () => {
    expect(withoutListedUntrackedContents(expanded).map((file) => file.path)).toEqual([
      "src/App.tsx",
      "target/",
    ]);
    // A sibling sharing the name prefix is not below the directory.
    expect(
      withoutListedUntrackedContents([untracked("target/", 200), untracked("targets.txt")]),
    ).toHaveLength(2);
  });

  test("find the summary containing a repository-relative path in its own repository", () => {
    const files = [untracked("target/", 200, "A"), untracked("target/", 300, "B")];
    expect(findContainingUntrackedDirectory(files, "C:/workspace/B", "target/debug/app")).toBe(
      files[1],
    );
    expect(findContainingUntrackedDirectory(files, "C:/workspace/C", "target/app")).toBeUndefined();
    expect(findContainingUntrackedDirectory(files, "C:/workspace/A", "target/")).toBeUndefined();
  });

  test("color project tree entries below a summary as untracked", () => {
    const lookup = createFileTreeGitStatusLookup({
      branch: "main",
      ahead: 0,
      behind: 0,
      files: [untracked("rust/core/target/", 5_273)],
    });
    const decoration = (path: string, isDir = false) =>
      getFileTreeEntryGitStatusDecoration(
        { name: path.split("/").pop()!, path: `C:/repo/${path}`, isDir },
        "C:/repo",
        lookup,
      )?.colorClassName;
    expect(decoration("rust/core/target/debug/app")).toBe("text-git-untracked");
    expect(decoration("rust/core/target/debug", true)).toBe("text-git-untracked");
    expect(decoration("rust/core/target", true)).toBe("text-git-untracked");
    expect(decoration("rust/core/src/lib.rs")).toBeUndefined();
  });

  test("hide gutter markers for a file below a summary", () => {
    const files = [untracked("target/", 200, "A")];
    expect(isGitGutterFileUntracked(files, "C:/workspace/A", "target/debug/app")).toBe(true);
    expect(isGitGutterFileUntracked(files, "C:/workspace/B", "target/debug/app")).toBe(false);
    expect(isGitGutterFileUntracked(files, "C:/workspace/A", "src/main.rs")).toBe(false);
  });

  test("delete a summary once instead of again for each listed file", () => {
    expect(resolveGitStatusDeletionPaths([{ files: expanded }])).toEqual([
      "src/App.tsx",
      "target/",
    ]);
  });
});

test("directory rows consume the Core projection and unknown membership fails closed", () => {
  const first = untracked("target/a.o", undefined, "A");
  const unknown = untracked("target/new.o", undefined, "A");
  const state: LocalChangelists = {
    ...EMPTY_CHANGELISTS,
    lists: [...EMPTY_CHANGELISTS.lists, { id: "local", name: "Local" }],
    assignments: { '["C:/workspace/A","target/"]': "local" },
    projection: {
      members: new Map([[changelistFileKey(first)!, "local"]]),
      scope: { include: false, paths: { A: ["target/", "target/a.o"] } },
    },
  };
  expect(fileChangelist(state, first)).toBe("local");
  expect(fileChangelist(state, unknown)).not.toBe(DEFAULT_CHANGELIST);
});
