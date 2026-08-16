import { getFileDiff, getUntrackedFileDiff } from "../api/git-diff-api";
import type { GitDiff, GitFile } from "../types/git.types";

export async function loadWorkingTreeFileDiff(
  repoPath: string,
  file: GitFile,
): Promise<GitDiff | null> {
  if (file.status !== "untracked" || file.staged) {
    return getFileDiff(repoPath, file.path, file.staged);
  }

  return getUntrackedFileDiff(repoPath, file.path);
}
