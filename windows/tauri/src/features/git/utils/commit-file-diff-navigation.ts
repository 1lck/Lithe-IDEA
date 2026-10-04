import type { ReviewRow } from "@lithe/editor/diff-review";
import type { MultiFileDiff } from "../types/git-diff.types";
import { getMultiDiffSectionKey } from "./multi-diff-search";

export function selectedCommitFileIndex(data: MultiFileDiff): number {
  const key = data.initiallySelectedFileKey ?? data.initiallyExpandedFileKey;
  const index = data.files.findIndex(
    (diff, index) => getMultiDiffSectionKey(data, diff, index) === key,
  );
  return index >= 0 ? index : data.files.length ? 0 : -1;
}

/** No wrapping: preserve the complete snapshot and change only the visible entry. */
export function moveCommitFile(data: MultiFileDiff, direction: -1 | 1): MultiFileDiff | null {
  const index = selectedCommitFileIndex(data);
  const target = index + direction;
  if (index < 0 || target < 0 || target >= data.files.length) return null;
  const key = getMultiDiffSectionKey(data, data.files[target], target);
  return { ...data, initiallySelectedFileKey: key, initiallyExpandedFileKey: key };
}

export interface DiffNavigationState {
  ready: boolean;
  count: number;
  canPrevious: boolean;
  canNext: boolean;
  canJumpToSource: boolean;
}

export const emptyDiffNavigation: DiffNavigationState = {
  ready: false,
  count: 0,
  canPrevious: false,
  canNext: false,
  canJumpToSource: false,
};

/** Continue forward through the snapshot only after the current comparison is ready. */
export function commitDifferenceNavigation(
  navigation: DiffNavigationState,
  fileIndex: number,
  fileCount: number,
): DiffNavigationState {
  return {
    ...navigation,
    canNext: navigation.ready &&
      (navigation.canNext || (fileIndex >= 0 && fileIndex < fileCount - 1)),
  };
}

export function differenceStartLine(
  change: { modifiedStartLineNumber: number; modifiedEndLineNumber: number },
  lineCount: number,
): number {
  return Math.min(lineCount, Math.max(1,
    change.modifiedStartLineNumber + (change.modifiedEndLineNumber === 0 ? 1 : 0)));
}

/** Monaco line changes use the preceding line for an empty modified range. */
export function differenceNavigationState(
  changes: readonly { modifiedStartLineNumber: number; modifiedEndLineNumber: number }[],
  cursorLine: number,
  lineCount: number,
): Pick<DiffNavigationState, "count" | "canPrevious" | "canNext"> {
  const starts = changes.map((change) => differenceStartLine(change, lineCount));
  return {
    count: starts.length,
    canPrevious: starts.some((line) => line < cursorLine),
    canNext: starts.some((line) => line > cursorLine),
  };
}

/** Map a historical caret to the newer revision; removed lines use the nearest surviving line. */
export function reviewSourceLine(
  rows: readonly ReviewRow[],
  side: "left" | "right",
  line: number,
): number | null {
  const visible = rows.filter((row) => row[side] !== null);
  const row = visible[line - 1];
  if (!row) return null;
  if (row.newLine !== null) return row.newLine;
  const index = rows.indexOf(row);
  for (let next = index + 1; next < rows.length; next++) {
    if (rows[next].newLine !== null) return rows[next].newLine;
  }
  for (let previous = index - 1; previous >= 0; previous--) {
    if (rows[previous].newLine !== null) return rows[previous].newLine;
  }
  return null;
}
