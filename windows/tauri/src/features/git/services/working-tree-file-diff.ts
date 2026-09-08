import {
  getFileDiff,
  getUntrackedFileDiff,
  getWorkingTreePathDiff,
} from "../api/git-diff-api";
import type { GitDiff, GitFile } from "../types/git.types";
import {
  getGitFileOriginalRepositoryRelativePath,
  getGitFileRepositoryRelativePath,
} from "../utils/git-status-selection";

export async function loadWorkingTreeFileDiff(
  repoPath: string,
  file: GitFile,
  wholePathSnapshot = false,
): Promise<GitDiff | null> {
  const filePath = getGitFileRepositoryRelativePath(file);
  const originalPath = getGitFileOriginalRepositoryRelativePath(file);
  if (wholePathSnapshot) {
    return getWorkingTreePathDiff(
      repoPath,
      filePath,
      file.status === "untracked",
      originalPath,
    );
  }
  if (file.status !== "untracked" || file.staged) {
    return getFileDiff(repoPath, filePath, file.staged);
  }

  return getUntrackedFileDiff(repoPath, filePath);
}
