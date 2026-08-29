import { describe, expect, test } from "bun:test";
import type { GitDiff } from "../types/git.types";
import { createCommitDiffBuffer } from "./multi-file-diff";

const diff = (filePath: string, additions: number, deletions: number): GitDiff => ({
  file_path: filePath,
  is_new: false,
  is_deleted: false,
  is_renamed: false,
  lines: [],
  additions,
  deletions,
});

describe("commit diff buffers", () => {
  test("opens a selected commit file in the multi-file diff page", () => {
    const diffs = [diff("src/main.ts", 2, 1), diff("src/feature.ts", 4, 3)];
    const buffer = createCommitDiffBuffer({
      repoPath: "C:/repo",
      commitHash: "1234567890abcdef",
      diffs,
      initialFilePath: "src/feature.ts",
      commit: {
        message: "Add feature",
        description: "",
        author: "Lithe",
        date: "2026-08-29",
      },
    });

    expect(buffer.virtualPath).toBe("diff://commit/1234567890abcdef/all-files");
    expect(buffer.displayName.endsWith(".diff")).toBe(false);
    expect(buffer.diffData.files).toBe(diffs);
    expect(buffer.diffData.initiallyExpandedFileKey).toBe("src/feature.ts:1");
    expect(buffer.diffData.initiallySelectedFileKey).toBe("src/feature.ts:1");
    expect(buffer.diffData.totalAdditions).toBe(6);
    expect(buffer.diffData.totalDeletions).toBe(4);
  });
});
