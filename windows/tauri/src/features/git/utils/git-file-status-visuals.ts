import type { GitFile } from "../types/git.types";

export function getWorkingTreeStatusColorClassName(status: GitFile["status"]): string {
  switch (status) {
    case "added":
      return "text-git-added";
    case "modified":
      return "text-info";
    case "deleted":
      return "text-subtle-foreground";
    case "untracked":
      return "text-git-deleted";
    case "renamed":
      return "text-git-renamed";
  }
}

export function getCommitFileStatusColorClassName(status: string): string {
  if (status.startsWith("A")) return "text-git-added";
  if (status.startsWith("M")) return "text-info";
  if (status.startsWith("D")) return "text-subtle-foreground";
  if (status.startsWith("R")) return "text-git-renamed";
  return "text-foreground";
}
