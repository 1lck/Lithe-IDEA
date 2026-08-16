import { beforeEach, describe, expect, mock, test } from "bun:test";
import type { GitDiff } from "../types/git.types";

const trackedDiff = { file_path: "tracked.txt" } as GitDiff;
const untrackedDiff = { file_path: "new.txt", is_new: true } as GitDiff;
const getFileDiff = mock(async () => trackedDiff);
const getUntrackedFileDiff = mock(async () => untrackedDiff);

mock.module("../api/git-diff-api", () => ({ getFileDiff, getUntrackedFileDiff }));

const { loadWorkingTreeFileDiff } = await import("./working-tree-file-diff");

beforeEach(() => {
  getFileDiff.mockClear();
  getUntrackedFileDiff.mockClear();
});

describe("working-tree file diffs", () => {
  test("routes untracked files through the shared Core diff contract", async () => {
    await expect(
      loadWorkingTreeFileDiff("C:/repo", {
        path: "new.txt",
        status: "untracked",
        staged: false,
      }),
    ).resolves.toBe(untrackedDiff);

    expect(getUntrackedFileDiff).toHaveBeenCalledWith("C:/repo", "new.txt");
    expect(getFileDiff).not.toHaveBeenCalled();
  });

  test("keeps tracked files on the regular diff path", async () => {
    await expect(
      loadWorkingTreeFileDiff("C:/repo", {
        path: "tracked.txt",
        status: "modified",
        staged: true,
      }),
    ).resolves.toBe(trackedDiff);

    expect(getFileDiff).toHaveBeenCalledWith("C:/repo", "tracked.txt", true);
  });
});
