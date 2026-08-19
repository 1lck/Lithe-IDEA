import { describe, expect, mock, test } from "bun:test";
import type { GitStatus } from "../types/git.types";
import { buildWorkingTreeMultiDiff } from "./working-tree-multi-diff";

describe("working-tree multi diff failures", () => {
  test("finishes indexing when an individual file cannot be loaded", async () => {
    const status: GitStatus = {
      branch: "main",
      ahead: 0,
      behind: 0,
      files: [{ path: "unreadable.txt", status: "untracked", staged: false }],
    };
    const loadDiff = mock(async () => {
      throw new Error("permission denied");
    });

    const result = await buildWorkingTreeMultiDiff({
      repoPath: "C:/repo",
      status,
      loadDiff,
    });

    expect(result.files).toEqual([]);
    expect(result.isLoading).toBe(false);
    expect(result.indexingProgress).toEqual({
      processed: 1,
      total: 1,
      label: "Indexing",
    });
  });
});
