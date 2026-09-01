import { describe, expect, test } from "bun:test";
import type { GitFile } from "../types/git.types";
import {
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
    expect([...presentation.fileByPath.keys()]).toEqual([
      "src/tracked.ts",
      "src/new.ts",
    ]);
  });

  test("coalesces an index deletion and same-path recreation for whole-path review", () => {
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
        status: "modified",
        worktree: true,
      },
    ]);
    expect(buildGitStatusPresentation(splitStatus).visibleFiles).toEqual(
      visible.files,
    );
  });
});
