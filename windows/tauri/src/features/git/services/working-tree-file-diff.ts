import {
  getFileDiff,
  getUntrackedFileDiff,
  getWorkingTreePathDiff,
} from "../api/git-diff-api";
import type { GitDiff, GitFile } from "../types/git.types";

export async function loadWorkingTreeFileDiff(
  repoPath: string,
  file: GitFile,
  wholePathSnapshot = false,
): Promise<GitDiff | null> {
  if (wholePathSnapshot) {
    return getWorkingTreePathDiff(
      repoPath,
      file.path,
      file.status === "untracked",
      file.originalPath,
    );
  }
  if (file.status !== "untracked" || file.staged) {
    return getFileDiff(repoPath, file.path, file.staged);
  }

  return getUntrackedFileDiff(repoPath, file.path);
}
