import type { GitDiff } from "../types/git.types";

function splitFileLines(content: string): string[] {
  if (content.length === 0) return [];

  const lines = content.split(/\r\n|\n|\r/);
  if (/\r\n$|\n$|\r$/.test(content)) {
    lines.pop();
  }
  return lines;
}

export function createUntrackedFileDiff(filePath: string, content: string): GitDiff {
  const fileLines = splitFileLines(content);
  const hunkHeader = `@@ -0,0 +1,${fileLines.length} @@`;

  return {
    file_path: filePath,
    old_path: "/dev/null",
    new_path: filePath,
    is_new: true,
    is_deleted: false,
    is_renamed: false,
    additions: fileLines.length,
    deletions: 0,
    lines: [
      { line_type: "header", content: hunkHeader },
      ...fileLines.map((line, index) => ({
        line_type: "added" as const,
        content: line,
        new_line_number: index + 1,
      })),
    ],
    split_hunks: [
      fileLines.map((line, index) => ({
        kind: "addition" as const,
        new_line_number: index + 1,
        new_content: line,
      })),
    ],
  };
}
