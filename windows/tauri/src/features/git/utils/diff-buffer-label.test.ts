import { describe, expect, test } from "bun:test";
import type { MultiFileDiff } from "@/features/git/types/git-diff.types";
import { formatDiffBufferLabel, getCommitPreviewFileName } from "./diff-buffer-label";

const WORKING_TREE_PATH = "diff://working-tree/all-files";

function workingTreeDiff(overrides: Partial<MultiFileDiff> = {}): MultiFileDiff {
  return {
    commitHash: "working-tree",
    files: [],
    totalFiles: 0,
    totalAdditions: 0,
    totalDeletions: 0,
    ...overrides,
  };
}

const translate = (key: string, params?: Record<string, string>) =>
  params ? `${key}(${Object.values(params).join(",")})` : key;

describe("formatDiffBufferLabel", () => {
  test("titles a commit-panel diff after the selected change like IntelliJ's commit preview", () => {
    const diff = workingTreeDiff({
      commitPreview: true,
      initiallyExpandedFileKey: "unstaged:src/features/bottom-pane.tsx",
      workingTreeTargets: {
        "unstaged:src/features/bottom-pane.tsx": {
          repoPath: "repo",
          filePath: "src/features/bottom-pane.tsx",
          untracked: false,
        },
      },
    });

    expect(formatDiffBufferLabel("Uncommitted Changes", WORKING_TREE_PATH, undefined, diff)).toBe(
      "Commit: bottom-pane.tsx",
    );
    expect(formatDiffBufferLabel("Uncommitted Changes", WORKING_TREE_PATH, translate, diff)).toBe(
      "git.diff.commitPreviewTitle(bottom-pane.tsx)",
    );
  });

  test("falls back to the bare commit title before any change is selected", () => {
    const diff = workingTreeDiff({ commitPreview: true });
    expect(formatDiffBufferLabel("Uncommitted Changes", WORKING_TREE_PATH, undefined, diff)).toBe(
      "Commit",
    );
  });

  test("keeps the generic title for working-tree diffs opened outside the commit panel", () => {
    // The editor gutter reuses the same tab but is not IntelliJ's commit preview.
    const gutterDiff = workingTreeDiff({ initiallyExpandedFileKey: "unstaged:src/a.ts" });

    expect(formatDiffBufferLabel("x", WORKING_TREE_PATH, translate, gutterDiff)).toBe(
      "git.diff.uncommitted",
    );
    expect(getCommitPreviewFileName(gutterDiff)).toBeNull();
  });

  test("prefers the selected file and strips the staging prefix without a target", () => {
    const diff = workingTreeDiff({
      commitPreview: true,
      initiallyExpandedFileKey: "unstaged:a.ts",
      initiallySelectedFileKey: "staged:lib/b.ts",
    });

    expect(getCommitPreviewFileName(diff)).toBe("b.ts");
  });

  test("keeps existing labels for other diff paths", () => {
    expect(formatDiffBufferLabel("x", "diff://staged/src/a.ts")).toBe("a.ts (staged)");
    expect(formatDiffBufferLabel("x", "diff://commit/0123456789abcdef/all-files")).toBe(
      "Commit 0123456",
    );
  });
});
