import { readFile } from "@/features/file-system/controllers/platform";
import { joinPath } from "@/utils/path-helpers";
import { getFileDiff } from "../api/git-diff-api";
import type { GitDiff, GitFile } from "../types/git.types";
import { createUntrackedFileDiff } from "../utils/untracked-file-diff";

export async function loadWorkingTreeFileDiff(
  repoPath: string,
  file: GitFile,
): Promise<GitDiff | null> {
  if (file.status !== "untracked" || file.staged) {
    return getFileDiff(repoPath, file.path, file.staged);
  }

  const content = await readFile(joinPath(repoPath, file.path));
  return createUntrackedFileDiff(file.path, content);
}
