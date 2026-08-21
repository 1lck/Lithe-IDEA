import type { DiffLineWithIndex, ParsedHunk } from "../types/git-diff.types";
import type { GitDiff, GitDiffLine, GitDiffSplitRow, GitHunk } from "../types/git.types";
export { getDiffLineVisualState, getDiffLineVisualType } from "./diff-viewer-visuals";

export interface DiffHunkRange {
  oldStart: number;
  oldCount: number;
  newStart: number;
  newCount: number;
  context: string;
}

export function parseDiffHunkRange(content: string): DiffHunkRange | null {
  const match = content.match(/@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)/);
  if (!match) return null;

  return {
    oldStart: Number(match[1]),
    oldCount: Number(match[2] || "1"),
    newStart: Number(match[3]),
    newCount: Number(match[4] || "1"),
    context: match[5]?.trim() || "",
  };
}

export function getSkippedUnchangedLineCount(
  previousHunk: ParsedHunk | undefined,
  currentHunk: ParsedHunk,
): number | null {
  const currentRange = parseDiffHunkRange(currentHunk.header.content);
  if (!currentRange) return null;

  if (!previousHunk) {
    const skippedBeforeFirstHunk = Math.min(
      Math.max(currentRange.oldStart - 1, 0),
      Math.max(currentRange.newStart - 1, 0),
    );

    return skippedBeforeFirstHunk > 0 ? skippedBeforeFirstHunk : null;
  }

  const previousRange = parseDiffHunkRange(previousHunk.header.content);
  if (!previousRange) return null;

  const previousOldEnd = previousRange.oldStart + previousRange.oldCount - 1;
  const previousNewEnd = previousRange.newStart + previousRange.newCount - 1;
  const skippedLines = Math.min(
    currentRange.oldStart - previousOldEnd - 1,
    currentRange.newStart - previousNewEnd - 1,
  );

  return skippedLines > 0 ? skippedLines : null;
}

export const createGitHunk = (
  hunk: { header: GitDiffLine; lines: GitDiffLine[] },
  filePath: string,
): GitHunk => ({
  file_path: filePath,
  lines: [hunk.header, ...hunk.lines],
});

export const getImgSrc = (base64: string | undefined) =>
  base64 ? `data:image/*;base64,${base64}` : undefined;

export function getFileStatus(diff: GitDiff): string {
  if (diff.is_new) return "added";
  if (diff.is_deleted) return "deleted";
  if (diff.is_renamed) return "renamed";
  return "modified";
}

export function groupLinesIntoHunks(lines: GitDiffLine[]): ParsedHunk[] {
  const hunks: ParsedHunk[] = [];
  let currentHunk: DiffLineWithIndex[] = [];
  let hunkHeader: GitDiffLine | null = null;
  let hunkId = 0;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (line.line_type === "header") {
      if (hunkHeader && currentHunk.length > 0) {
        hunks.push({
          header: hunkHeader,
          lines: currentHunk,
          id: hunkId++,
        });
      }
      hunkHeader = line;
      currentHunk = [];
    } else {
      currentHunk.push({ ...line, diffIndex: i });
    }
  }

  if (hunkHeader && currentHunk.length > 0) {
    hunks.push({
      header: hunkHeader,
      lines: currentHunk,
      id: hunkId,
    });
  }

  return hunks;
}

export function createFallbackSplitRows(lines: DiffLineWithIndex[]): GitDiffSplitRow[] {
  const rows: GitDiffSplitRow[] = [];
  let index = 0;

  while (index < lines.length) {
    const line = lines[index];
    if (line.line_type === "context") {
      rows.push({
        kind: "context",
        old_line_number: line.old_line_number,
        new_line_number: line.new_line_number,
        old_content: line.content,
        new_content: line.content,
      });
      index++;
      continue;
    }

    const removed: DiffLineWithIndex[] = [];
    const added: DiffLineWithIndex[] = [];
    while (index < lines.length && lines[index].line_type !== "context") {
      const changedLine = lines[index];
      if (changedLine.line_type === "removed") removed.push(changedLine);
      if (changedLine.line_type === "added") added.push(changedLine);
      index++;
    }

    const rowCount = Math.max(removed.length, added.length);
    for (let rowIndex = 0; rowIndex < rowCount; rowIndex++) {
      const oldLine = removed[rowIndex];
      const newLine = added[rowIndex];
      rows.push({
        kind:
          oldLine && newLine
            ? oldLine.content === newLine.content
              ? "context"
              : "changed"
            : oldLine
              ? "removal"
              : "addition",
        old_line_number: oldLine?.old_line_number,
        new_line_number: newLine?.new_line_number,
        old_content: oldLine?.content,
        new_content: newLine?.content,
      });
    }
  }

  return rows;
}

export function countSplitDiffStats(splitHunks: GitDiffSplitRow[][]): {
  additions: number;
  deletions: number;
} {
  let additions = 0;
  let deletions = 0;

  for (const row of splitHunks.flat()) {
    if (row.kind === "addition" || row.kind === "changed") additions++;
    if (row.kind === "removal" || row.kind === "changed") deletions++;
  }

  return { additions, deletions };
}

export function hasInvisibleDiffChanges(rows: GitDiffSplitRow[]): boolean {
  return rows.some((row) => row.is_invisible_change === true);
}

export function countDiffStats(diffs: GitDiff[]): { additions: number; deletions: number } {
  let additions = 0;
  let deletions = 0;
  for (const diff of diffs) {
    if (typeof diff.additions === "number" || typeof diff.deletions === "number") {
      additions += diff.additions ?? 0;
      deletions += diff.deletions ?? 0;
      continue;
    }

    for (const line of diff.lines) {
      if (line.line_type === "added") additions++;
      else if (line.line_type === "removed") deletions++;
    }
  }
  return { additions, deletions };
}
