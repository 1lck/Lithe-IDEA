import type { ReviewRow } from "@lithe/editor/diff-review";
import type { GitDiff, GitDiffLine, GitFile, GitHunk } from "../types/git.types";
import { normalizeRepositoryPath } from "../api/git-repository-path";
import { parseDiffHunkRange } from "./git-diff-helpers";

/** Aggregated workspace status must match both repository and relative path. */
export function isGitGutterFileUntracked(
  files: readonly GitFile[],
  repoPath: string,
  filePath: string,
): boolean {
  return files.some((file) =>
    file.status === "untracked" &&
    (!file.repositoryPath ||
      normalizeRepositoryPath(file.repositoryPath) === normalizeRepositoryPath(repoPath)) &&
    (file.repositoryRelativePath ?? file.path) === filePath,
  );
}

export type GitGutterChangeKind = "added" | "modified" | "deleted";

/** One-based, end-exclusive line ranges, as Monaco's line diff reports them. */
export interface GitGutterLineRange {
  originalStart: number;
  originalEnd: number;
  modifiedStart: number;
  modifiedEnd: number;
}

/** One contiguous change between the Git base text and the editor text. */
export interface GitGutterChange extends GitGutterLineRange {
  kind: GitGutterChangeKind;
  originalLines: string[];
  modifiedLines: string[];
}

/** Returns null when the comparison could not finish within its budget. */
export type GitGutterLineDiff = (
  original: readonly string[],
  modified: readonly string[],
) => GitGutterLineRange[] | null;

/**
 * Where the editor's comparison base comes from. `unchanged` means Git found
 * no difference between the index and the file on disk, so the saved disk
 * text is the base.
 */
export type GitGutterBaseSource = { kind: "lines"; lines: string[] } | { kind: "unchanged" };

/** Context kept around a staged gutter change. Matches Git's default `--unified=3`. */
const GITGUTTER_HUNK_CONTEXT_LINES = 3;

/**
 * Splits text the way an editor counts lines. A trailing line break does not
 * start another line, so `"a\n"` and `"a"` both compare as `["a"]`; the Git
 * diff parser drops end-of-file newline markers in the same way.
 */
export function splitGitGutterLines(text: string): string[] {
  if (text === "") return [];
  const lines = text.split(/\r\n|\r|\n/);
  if (lines[lines.length - 1] === "") lines.pop();
  return lines;
}

/** Drops the empty line Monaco reports after a final line break. */
export function trimFinalEmptyLine(lines: readonly string[]): string[] {
  return lines.length > 0 && lines[lines.length - 1] === "" ? lines.slice(0, -1) : [...lines];
}

/**
 * Rebuilds the index text from a full-context index-to-worktree patch. The
 * old side of such a patch is the complete index version: every context and
 * removed line, in order. Sparse, truncated or binary patches cannot supply
 * that text and return null instead of a partial base.
 */
export function gitGutterBaseFromDiff(diff: GitDiff | null): GitGutterBaseSource | null {
  // A null diff means the read failed or the file is outside a repository;
  // an empty patch (no lines) is how Git reports an unchanged file.
  if (!diff || diff.is_binary || diff.is_image || diff.is_truncated) return null;
  const headers = diff.lines.filter((line) => line.line_type === "header");
  if (headers.length === 0) return diff.lines.length === 0 ? { kind: "unchanged" } : null;
  if (headers.length > 1 || !diff.is_full_context || diff.lines[0]?.line_type !== "header") {
    return null;
  }
  const range = parseDiffHunkRange(headers[0].content);
  if (!range) return null;
  const lines = diff.lines
    .filter((line) => line.line_type === "context" || line.line_type === "removed")
    .map((line) => line.content);
  const expectedStart = range.oldCount === 0 ? 0 : 1;
  if (range.oldStart !== expectedStart || lines.length !== range.oldCount) return null;
  return { kind: "lines", lines };
}

export function computeGitGutterChanges(
  original: readonly string[],
  modified: readonly string[],
  lineDiff: GitGutterLineDiff,
): GitGutterChange[] | null {
  const ranges = lineDiff(original, modified);
  if (!ranges) return null;
  return ranges.map((range) => ({
    ...range,
    kind:
      range.originalStart === range.originalEnd
        ? "added"
        : range.modifiedStart === range.modifiedEnd
          ? "deleted"
          : "modified",
    originalLines: original.slice(range.originalStart - 1, range.originalEnd - 1),
    modifiedLines: modified.slice(range.modifiedStart - 1, range.modifiedEnd - 1),
  }));
}

/**
 * Editor lines that carry a change's gutter marker. Deleted lines have no
 * editor line of their own, so they mark the line that now follows them, or
 * the last line when the deletion is at the end of the file (as on macOS).
 */
export function gitGutterMarkerLines(
  change: GitGutterChange,
  lineCount: number,
): { start: number; end: number } {
  const lastLine = Math.max(1, lineCount);
  if (change.kind === "deleted") {
    const line = Math.min(Math.max(1, change.modifiedStart), lastLine);
    return { start: line, end: line };
  }
  return {
    start: Math.min(change.modifiedStart, lastLine),
    end: Math.min(change.modifiedEnd - 1, lastLine),
  };
}

/** The editor line below which a change's inline review opens. Zero means above line 1. */
export function gitGutterPeekAnchorLine(change: GitGutterChange): number {
  return change.kind === "deleted" ? change.modifiedStart - 1 : change.modifiedEnd - 1;
}

export function gitGutterChangeIndexAtLine(
  changes: readonly GitGutterChange[],
  line: number,
  lineCount: number,
): number {
  // A deletion can share its marker line with the start of the next change;
  // the change that owns real editor lines wins that click.
  let deletion = -1;
  for (let index = 0; index < changes.length; index++) {
    const { start, end } = gitGutterMarkerLines(changes[index], lineCount);
    if (line < start || line > end) continue;
    if (changes[index].kind !== "deleted") return index;
    if (deletion < 0) deletion = index;
  }
  return deletion;
}

/** Previous and next wrap around, as VS Code's and IDEA's change navigation do. */
export function adjacentGitGutterChangeIndex(
  total: number,
  index: number,
  direction: "previous" | "next",
): number {
  if (total <= 0) return -1;
  return (index + (direction === "next" ? 1 : total - 1)) % total;
}

/** Unchanged lines shown above and below a change in its inline review. */
const GIT_GUTTER_PEEK_CONTEXT_LINES = 2;

/**
 * Rows for one change's read-only inline review: the change plus a little
 * unchanged context, with real line numbers on both sides. Context stops at
 * the neighbouring changes so it never shows another change as unchanged.
 */
export function gitGutterPeekRows(
  changes: readonly GitGutterChange[],
  index: number,
  editorLines: readonly string[],
  contextLines = GIT_GUTTER_PEEK_CONTEXT_LINES,
): ReviewRow[] {
  const change = changes[index];
  if (!change) return [];
  const previousEnd = index > 0 ? changes[index - 1].modifiedEnd : 1;
  const nextStart =
    index + 1 < changes.length ? changes[index + 1].modifiedStart : editorLines.length + 1;
  const context = (line: number, offset: number): ReviewRow => {
    const text = editorLines[line - 1] ?? "";
    return {
      id: `context-${line}`,
      oldLine: line + offset,
      newLine: line,
      left: text,
      right: text,
      kind: "context",
      hunkID: null,
    };
  };

  const rows: ReviewRow[] = [];
  const offsetBefore = change.originalStart - change.modifiedStart;
  for (
    let line = Math.max(previousEnd, change.modifiedStart - contextLines);
    line < change.modifiedStart;
    line++
  ) {
    rows.push(context(line, offsetBefore));
  }
  change.originalLines.forEach((text, offset) =>
    rows.push({
      id: `removed-${offset}`,
      oldLine: change.originalStart + offset,
      newLine: null,
      left: text,
      right: null,
      kind: "removal",
      hunkID: null,
    }),
  );
  change.modifiedLines.forEach((text, offset) =>
    rows.push({
      id: `added-${offset}`,
      oldLine: null,
      newLine: change.modifiedStart + offset,
      left: null,
      right: text,
      kind: "addition",
      hunkID: null,
    }),
  );
  const offsetAfter = change.originalEnd - change.modifiedEnd;
  const contextEnd = Math.min(nextStart, change.modifiedEnd + contextLines);
  for (let line = change.modifiedEnd; line < contextEnd; line++) {
    rows.push(context(line, offsetAfter));
  }
  return rows;
}

/** Identity of a change's content, used to keep a review open across refreshes. */
export function gitGutterChangeKey(change: GitGutterChange): string {
  return JSON.stringify([
    change.originalStart,
    change.originalEnd,
    change.modifiedStart,
    change.modifiedEnd,
    change.originalLines,
    change.modifiedLines,
  ]);
}

/**
 * Builds a patch that stages exactly one change against the index. Context
 * comes from the base (index) text, never from the editor, so a neighbouring
 * unstaged change inside the context window stays out of the index.
 */
export function gitGutterChangeHunk(
  filePath: string,
  base: readonly string[],
  change: GitGutterChange,
): GitHunk {
  const context = GITGUTTER_HUNK_CONTEXT_LINES;
  const removedStart = change.originalStart - 1;
  const removedEnd = change.originalEnd - 1;
  const contextStart = Math.max(0, removedStart - context);
  const contextEnd = Math.min(base.length, removedEnd + context);
  const leading = removedStart - contextStart;
  const trailing = contextEnd - removedEnd;
  const contextLine = (content: string): GitDiffLine => ({ line_type: "context", content });

  const oldCount = contextEnd - contextStart;
  const newCount = leading + change.modifiedLines.length + trailing;
  // Git names the line before an empty range, or 0 at the start of the file.
  const oldStart = oldCount === 0 ? contextStart : contextStart + 1;
  // This patch applies only this change to the index. Earlier unstaged
  // insertions/deletions must not shift its new-side coordinates.
  const firstNewLine = contextStart + 1;
  const newStart = newCount === 0 ? firstNewLine - 1 : firstNewLine;

  return {
    file_path: filePath,
    lines: [
      { line_type: "header", content: `@@ -${oldStart},${oldCount} +${newStart},${newCount} @@` },
      ...base.slice(contextStart, removedStart).map(contextLine),
      ...change.originalLines.map((content): GitDiffLine => ({ line_type: "removed", content })),
      ...change.modifiedLines.map((content): GitDiffLine => ({ line_type: "added", content })),
      ...base.slice(removedEnd, contextEnd).map(contextLine),
    ],
  };
}
