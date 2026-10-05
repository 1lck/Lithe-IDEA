import { createTwoFilesPatch } from "diff";
import type { GitDiff } from "../features/git/types/git.types";
import { parseRawDiffContent } from "../features/git/utils/git-diff-parser";

export function fullDiff(before: string[], after: string[]): GitDiff {
  if (before.join("\n") === after.join("\n")) return {
    file_path: "file.txt", is_full_context: true, is_new: false, is_deleted: false, is_renamed: false, lines: [],
  };
  const patch = createTwoFilesPatch("a/file.txt", "b/file.txt", before.join("\n") + "\n",
    after.join("\n") + "\n", undefined, undefined, { context: 10000 });
  const diff = parseRawDiffContent(patch, "file.txt") as GitDiff;
  return { ...diff, is_full_context: true };
}
