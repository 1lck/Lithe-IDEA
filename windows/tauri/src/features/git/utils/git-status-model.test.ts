import { describe, expect, test } from "bun:test";
import type { GitFile } from "../types/git.types";
import {
  buildGitFolderTree,
  buildGitStatusPresentation,
  buildVisibleGitFiles,
} from "./git-status-model";

const files: GitFile[] = [
  { path: "src/tracked.ts", status: "modified", staged: false },
  { path: "src/new.ts", status: "untracked", staged: false },
];

describe("Git status model", () => {
  test("keeps hidden untracked files out of both rendering and commit lookup", () => {
    const presentation = buildVisibleGitFiles(files, false);

    expect(presentation.files).toEqual([files[0]]);
    expect([...presentation.fileByPath.keys()]).toEqual(["src/tracked.ts"]);
    expect(presentation.fileByPath.has("src/new.ts")).toBe(false);
  });

  test("includes untracked files when the setting is enabled", () => {
    const presentation = buildVisibleGitFiles(files, true);
    expect(presentation.files).toEqual(files);
    expect([...presentation.fileByPath.keys()]).toEqual(["src/tracked.ts", "src/new.ts"]);
  });

  test("preserves the staged deletion when a worktree file is recreated", () => {
    const splitStatus: GitFile[] = [
      {
        path: "src/recreated.ts",
        status: "deleted",
        staged: true,
        rawStatus: "D ",
        worktree: false,
      },
      {
        path: "src/recreated.ts",
        status: "untracked",
        staged: false,
        rawStatus: "??",
        worktree: false,
      },
    ];

    const visible = buildVisibleGitFiles(splitStatus, false);
    expect(visible.files).toEqual([
      {
        ...splitStatus[0],
        worktree: true,
      },
    ]);
    expect(buildGitStatusPresentation(splitStatus).visibleFiles).toEqual(visible.files);
  });
});

describe("Git folder tree with untracked directory summaries", () => {
  const untracked = (path: string, untrackedFileCount?: number): GitFile => ({
    path,
    status: "untracked",
    staged: false,
    ...(untrackedFileCount === undefined ? {} : { untrackedFileCount }),
  });
  const names = (tree: ReturnType<typeof buildGitFolderTree>) => {
    const visit = (nodes: typeof tree.nodes): string[] =>
      nodes.flatMap((node) => [
        `${node.type}:${node.path}`,
        ...(node.type === "branch" ? visit(node.children) : []),
      ]);
    return visit(tree.nodes);
  };

  test("keeps a collapsed summary as one row", () => {
    const tree = buildGitFolderTree([untracked("rust/target/", 5_273)]);
    expect(names(tree)).toEqual(["branch:rust", "leaf:rust/target/"]);
    expect(tree.untrackedDirectoryByFolderPath.size).toBe(0);
  });

  test("lets the folder built from an expanded summary stand for it", () => {
    const summary = untracked("rust/target/", 5_273);
    const tree = buildGitFolderTree([
      summary,
      untracked("rust/target/.rustc_info.json"),
      untracked("rust/target/debug/", 5_272),
    ]);
    // The summary row would otherwise sit beside a folder of the same name.
    expect(names(tree)).toEqual([
      "branch:rust",
      "branch:rust/target",
      "leaf:rust/target/debug/",
      "leaf:rust/target/.rustc_info.json",
    ]);
    expect(tree.untrackedDirectoryByFolderPath.get("rust/target")).toBe(summary);
    expect(tree.folderStateById.get("branch:rust/target")?.descendantFilePaths).toEqual([
      "rust/target/debug/",
      "rust/target/.rustc_info.json",
    ]);
  });
});
