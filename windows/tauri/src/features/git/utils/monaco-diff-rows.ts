import type { ReviewRow } from "@lithe/editor/diff-review";
import type { GitDiff, GitHunk } from "../types/git.types";
import { parseDiffHunkRange } from "./git-diff-helpers";

/** Preserve patch order and identity. Monaco aligns the projections, while
 * search results continue to address the original Git line array. */
export function monacoDiffRows(diff: GitDiff): ReviewRow[] {
  let hunkID: string | null = null;
  return diff.lines.map((line, index) => {
    if (line.line_type === "header") hunkID = `hunk-${index}`;
    return {
      id: `line-${index}`,
      oldLine: line.old_line_number ?? null,
      newLine: line.new_line_number ?? null,
      left: line.line_type === "added" ? null : line.content,
      right: line.line_type === "removed" ? null : line.content,
      kind: line.line_type === "header" ? "information"
        : line.line_type === "added" ? "addition"
        : line.line_type === "removed" ? "removal" : "context",
      hunkID,
    };
  });
}

/** Resolve the host's patch identity, never Monaco's aligned display ranges. */
export function monacoDiffHunk(diff: GitDiff, hunkID: string): GitHunk | null {
  if (diff.is_truncated || !/^hunk-(0|[1-9]\d*)$/.test(hunkID)) return null;
  const start = Number(hunkID.slice(5));
  const header = diff.lines[start];
  if (header?.line_type !== "header" || !parseDiffHunkRange(header.content)) return null;
  let end = start + 1;
  while (end < diff.lines.length && diff.lines[end].line_type !== "header") end++;
  if (end === start + 1) return null;
  return { file_path: diff.file_path, lines: diff.lines.slice(start, end) };
}
