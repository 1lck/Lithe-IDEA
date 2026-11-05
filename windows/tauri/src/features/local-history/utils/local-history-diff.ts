import type { GitDiff, GitDiffLine, GitDiffSplitRow } from "@/features/git/types/git.types";
import { invoke } from "@/platform/tauri-core";
import { getBaseName } from "@/utils/path-helpers";

/** `diff.compareTexts` response; Core owns line splitting, matching, and pairing. */
export interface TextComparison {
  rows: {
    oldLine: number | null;
    newLine: number | null;
    left: string | null;
    right?: string | null;
    kind: GitDiffSplitRow["kind"];
  }[];
  lines: {
    kind: "context" | "removed" | "added";
    content: string;
    oldLine: number | null;
    newLine: number | null;
  }[];
  oldLineCount: number;
  newLineCount: number;
  additions: number;
  deletions: number;
}

export function compareTexts(oldText: string, newText: string): Promise<TextComparison> {
  return invoke<TextComparison>("diff.compareTexts", { oldText, newText });
}

/** Projects the shared comparison into the Windows diff viewer's model. */
export function toLocalHistoryDiff(filePath: string, comparison: TextComparison): GitDiff {
  const fileName = getBaseName(filePath, filePath);
  const lines: GitDiffLine[] = comparison.lines.length
    ? [
        {
          line_type: "header",
          content: `@@ -1,${comparison.oldLineCount} +1,${comparison.newLineCount} @@`,
        },
        ...comparison.lines.map((line) => ({
          line_type: line.kind,
          content: line.content,
          old_line_number: line.oldLine ?? undefined,
          new_line_number: line.newLine ?? undefined,
        })),
      ]
    : [];
  const splitRows: GitDiffSplitRow[] = comparison.rows.map((row) => ({
    kind: row.kind,
    old_line_number: row.oldLine ?? undefined,
    new_line_number: row.newLine ?? undefined,
    old_content: row.left ?? undefined,
    new_content: row.kind === "context" ? (row.left ?? undefined) : (row.right ?? undefined),
  }));
  return {
    file_path: fileName,
    old_path: fileName,
    new_path: fileName,
    is_new: comparison.oldLineCount === 0,
    is_deleted: comparison.newLineCount === 0,
    is_renamed: false,
    is_binary: false,
    is_image: false,
    lines,
    split_hunks: splitRows.length ? [splitRows] : [],
    additions: comparison.additions,
    deletions: comparison.deletions,
  };
}

export async function createLocalHistoryDiff(params: {
  filePath: string;
  oldContent: string;
  newContent: string;
}): Promise<GitDiff> {
  return toLocalHistoryDiff(params.filePath, await compareTexts(params.oldContent, params.newContent));
}
