import { expect, test } from "bun:test";
import type { ReviewRow } from "@lithe/editor/diff-review";
import type { GitDiff } from "../types/git.types";
import { createCommitFileDiffPreview } from "./multi-file-diff";
import { formatDiffBufferLabel } from "./diff-buffer-label";
import {
  selectedCommitFileIndex,
  moveCommitFile,
  differenceNavigationState,
  reviewSourceLine,
  commitDifferenceNavigation,
  emptyDiffNavigation,
  commitPreviewFilePosition,
} from "./commit-file-diff-navigation";
import { createCommitWorkingTreeFileOrder, createSingleFileWorkingTreeDiff } from "./working-tree-multi-diff";

test("Commit file order retains nested owners, deduplicates mixed files and navigates beyond its one loaded comparison", () => {
  const order = createCommitWorkingTreeFileOrder("C:/repo", [
    { path: "a.txt", status: "modified", staged: true, worktree: true },
    { path: "a.txt", status: "modified", staged: false, worktree: true },
    { path: "nested/b.txt", repositoryPath: "C:/repo/nested", repositoryRelativePath: "b.txt",
      status: "untracked", staged: false, worktree: true },
  ], false);
  expect(order.map(entry => entry.fileKey)).toEqual(["unstaged:a.txt", "unstaged:nested/b.txt"]);
  expect(order[1].target).toEqual({ repoPath: "C:/repo/nested", filePath: "b.txt", untracked: true });
  const data = createSingleFileWorkingTreeDiff({ repoPath: "C:/repo", fileKey: order[0].fileKey,
    target: order[0].target, diff: file("a.txt"), commitPreview: true, workingTreeFileOrder: order });
  expect(data.files).toHaveLength(1);
  expect(commitPreviewFilePosition(data)).toEqual({ index: 0, count: 2 });
  expect(commitDifferenceNavigation({ ...emptyDiffNavigation, ready: true }, 0, 2).canNext).toBe(true);
  const next = { ...data, initiallyExpandedFileKey: order[1].fileKey };
  expect(commitPreviewFilePosition(next)).toEqual({ index: 1, count: 2 });
  expect(commitDifferenceNavigation({ ...emptyDiffNavigation, ready: true }, 1, 2).canNext).toBe(false);
});

const file = (path: string): GitDiff => ({
  file_path: path,
  lines: [],
  is_new: false,
  is_deleted: false,
  is_renamed: false,
});

test("file navigation preserves repeated revisions, updates the tab and stops at both boundaries", () => {
  const preview = createCommitFileDiffPreview({
    repoPath: "C:/nested/repo",
    commitHash: "C",
    diffs: [file("a.ts"), file("b.ts"), file("a.ts")],
    fileKeys: ["C:a", "C:b", "A:a"],
    fileLabels: ["C", "C", "A"],
    filePath: "b.ts",
    label: "C",
  })!;
  const middle = preview.diffData;
  const first = moveCommitFile(middle, -1)!;
  const last = moveCommitFile(middle, 1)!;
  expect(selectedCommitFileIndex(middle)).toBe(1);
  expect(first.initiallySelectedFileKey).toBe("C:a");
  expect(first.initialDifference).toBe("last");
  expect(last.initiallySelectedFileKey).toBe("A:a");
  expect(last.initialDifference).toBe("first");
  expect(last.files).toBe(middle.files);
  expect(last.fileLabels?.[selectedCommitFileIndex(last)]).toBe("A");
  expect(last.repoPath).toBe("C:/nested/repo");
  expect(moveCommitFile(first, -1)).toBeNull();
  expect(moveCommitFile(last, 1)).toBeNull();
  const passive = { ...middle, preserveFocus: true };
  expect(moveCommitFile(passive, 1)?.preserveFocus).toBe(false);
  expect(moveCommitFile(passive, -1)?.preserveFocus).toBe(false);
  expect(formatDiffBufferLabel(preview.displayName, preview.virtualPath, undefined, middle)).toBe(
    "Repository Diff: b.ts",
  );
  expect(formatDiffBufferLabel(preview.displayName, preview.virtualPath, undefined, last)).toBe(
    "Repository Diff: a.ts",
  );
  expect(middle.initiallySelectedFileKey).toBe("C:b");
});

test("an empty preview has no navigation and the bare IDEA tab title", () => {
  const data = {
    commitHash: "x",
    files: [],
    totalFiles: 0,
    totalAdditions: 0,
    totalDeletions: 0,
    commitFilePreview: true,
  };
  expect(selectedCommitFileIndex(data)).toBe(-1);
  expect(moveCommitFile(data, 1)).toBeNull();
  expect(formatDiffBufferLabel("old", "diff://commit-file-preview", undefined, data)).toBe(
    "Repository Diff",
  );
});

test("difference boundaries include pure deletions without wrapping", () => {
  const changes = [
    { modifiedStartLineNumber: 3, modifiedEndLineNumber: 5 },
    { modifiedStartLineNumber: 9, modifiedEndLineNumber: 0 },
  ];
  expect(differenceNavigationState(changes, 1, 20)).toEqual({
    count: 2,
    canPrevious: false,
    canNext: true,
  });
  expect(differenceNavigationState(changes, 3, 20)).toEqual({
    count: 2,
    canPrevious: false,
    canNext: true,
  });
  expect(differenceNavigationState(changes, 10, 20)).toEqual({
    count: 2,
    canPrevious: true,
    canNext: false,
  });
  expect(
    differenceNavigationState([{ modifiedStartLineNumber: 20, modifiedEndLineNumber: 0 }], 20, 20)
      .canNext,
  ).toBe(false);
  expect(differenceNavigationState([], 1, 1)).toEqual({
    count: 0,
    canPrevious: false,
    canNext: false,
  });
});

test("source navigation projects historical lines and maps removed lines to surviving new lines", () => {
  const row = (id: string, oldLine: number | null, newLine: number | null): ReviewRow => ({
    id,
    oldLine,
    newLine,
    left: oldLine ? id : null,
    right: newLine ? id : null,
    kind: oldLine && newLine ? "context" : oldLine ? "removal" : "addition",
  });
  const rows = [
    row("context", 100, 90),
    row("removed", 101, null),
    row("replacement", null, 91),
    row("last", 102, 92),
    row("tail", 103, null),
  ];
  expect(reviewSourceLine(rows, "right", 2)).toBe(91);
  expect(reviewSourceLine(rows, "left", 2)).toBe(91);
  expect(reviewSourceLine(rows, "left", 4)).toBe(92);
  expect(reviewSourceLine([row("deleted", 30, null)], "left", 1)).toBeNull();
  expect(reviewSourceLine(rows, "right", 10)).toBeNull();
});

test("next difference continues at file boundaries but waits for each comparison and stops at the snapshot end", () => {
  const ready = { ...emptyDiffNavigation, ready: true };
  const changes = [{ modifiedStartLineNumber: 4, modifiedEndLineNumber: 4 },
    { modifiedStartLineNumber: 10, modifiedEndLineNumber: 10 }];
  for (const fileIndex of [0, 1]) {
    expect(commitDifferenceNavigation(emptyDiffNavigation, fileIndex, 3).canNext).toBe(false);
    expect(commitDifferenceNavigation({ ...ready, ...differenceNavigationState(changes, 4, 12) }, fileIndex, 3).canNext).toBe(true);
    expect(commitDifferenceNavigation({ ...ready, ...differenceNavigationState(changes, 10, 12) }, fileIndex, 3).canNext).toBe(true);
  }
  expect(commitDifferenceNavigation({ ...ready, ...differenceNavigationState(changes, 4, 12) }, 2, 3).canNext).toBe(true);
  expect(commitDifferenceNavigation({ ...ready, ...differenceNavigationState(changes, 10, 12) }, 2, 3).canNext).toBe(false);
  // Binary or unchanged entries still allow moving forward through the snapshot.
  expect(commitDifferenceNavigation(ready, 1, 3).canNext).toBe(true);
  expect(commitDifferenceNavigation(ready, 2, 3).canNext).toBe(false);
  expect(commitDifferenceNavigation(ready, -1, 0).canNext).toBe(false);
});

test("previous difference crosses file boundaries only when ready and stops at the snapshot start", () => {
  const ready = { ...emptyDiffNavigation, ready: true };
  expect(commitDifferenceNavigation(ready, 0, 3).canPrevious).toBe(false);
  expect(commitDifferenceNavigation(ready, 1, 3).canPrevious).toBe(true);
  expect(commitDifferenceNavigation(ready, 2, 3).canPrevious).toBe(true);
  expect(commitDifferenceNavigation(emptyDiffNavigation, 2, 3).canPrevious).toBe(false);
  expect(commitDifferenceNavigation(ready, -1, 0).canPrevious).toBe(false);
  expect(commitDifferenceNavigation({ ...ready, canPrevious: true }, 0, 3).canPrevious).toBe(true);
});
