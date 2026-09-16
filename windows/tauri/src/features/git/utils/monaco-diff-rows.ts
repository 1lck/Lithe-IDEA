import type { ReviewRow } from "@lithe/editor/diff-review";
import type { GitDiff } from "../types/git.types";

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
