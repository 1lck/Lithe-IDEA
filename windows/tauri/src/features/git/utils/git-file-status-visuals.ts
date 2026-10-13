import type { GitFile } from "../types/git.types";

// File-status colors follow IntelliJ's FileStatus palette through the git-* theme
// tokens: modified/renamed blue, added green, deleted gray, unversioned red.

export function getWorkingTreeStatusColorClassName(status: GitFile["status"]): string {
  switch (status) {
    case "added":
      return "text-git-added";
    case "modified":
      return "text-git-modified";
    case "deleted":
      return "text-git-file-deleted";
    case "untracked":
      return "text-git-untracked";
    case "renamed":
      return "text-git-renamed";
  }
}

export function getCommitFileStatusColorClassName(status: string): string {
  if (status.startsWith("A")) return "text-git-added";
  if (status.startsWith("M")) return "text-git-modified";
  if (status.startsWith("D")) return "text-git-file-deleted";
  if (status.startsWith("R")) return "text-git-renamed";
  return "text-foreground";
}
