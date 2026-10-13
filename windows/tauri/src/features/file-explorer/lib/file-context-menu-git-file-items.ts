import type { ReactNode } from "react";
import type { WorkingTreeDiffTarget } from "@/features/git/types/git-diff.types";
import type { GitDiff, GitFile } from "@/features/git/types/git.types";
import type { MenuItem } from "@/ui/dropdown";

/** Git status slice the per-file context menu decisions depend on. */
export interface ExplorerGitFileMenuState {
  status: "modified" | "added" | "deleted" | "untracked" | "renamed";
  staged: boolean;
  worktree?: boolean;
  canToggleStaging?: boolean;
}

export interface ExplorerGitFileMenuCapabilities {
  showDiff: boolean;
  add: boolean;
  commitFile: boolean;
}

export interface GitFileContextMenuLabels {
  submenu: string;
  showDiff: string;
  add: string;
  commitFile: string;
}

export interface GitFileContextMenuActions {
  showDiff: () => void;
  add: () => void;
  commitFile: () => void;
}

export interface GitFileContextMenuIcons {
  submenu?: ReactNode;
  showDiff?: ReactNode;
  add?: ReactNode;
  commitFile?: ReactNode;
}

export interface GitFileContextMenuOptions {
  labels: GitFileContextMenuLabels;
  actions: GitFileContextMenuActions;
  icons?: GitFileContextMenuIcons;
  capabilities: ExplorerGitFileMenuCapabilities;
  disabled?: boolean;
}

const VIRTUAL_PATH_PREFIXES = ["remote://", "wsl://", "diff://"];

/** Paths that live in virtual buffer namespaces and never map to a Git work tree. */
export function isVirtualWorkspacePath(path: string): boolean {
  return VIRTUAL_PATH_PREFIXES.some((prefix) => path.startsWith(prefix));
}

function toForwardSlashes(path: string): string {
  return path.replace(/\\/g, "/");
}

/** A diff is worth opening when it has rows, or is an image/binary payload. */
export function hasGitDiffContent(diff: GitDiff | null): diff is GitDiff {
  return Boolean(diff && (diff.lines.length > 0 || diff.is_image || diff.is_binary));
}

export interface GitFileDiffTarget {
  target: WorkingTreeDiffTarget;
  /** Key format shared with the working-tree diff stack refresh identity. */
  fileKey: string;
}

/**
 * Builds the working-tree diff target so the opened buffer carries the owning
 * repository. Refreshes then re-read through target.repoPath instead of
 * guessing the workspace root, which breaks in nested/multi-repo workspaces
 * (per review on PR #989). Field shape mirrors use-git-diff-actions.ts.
 */
export function buildWorkingTreeDiffTarget(
  context: {
    repoPath: string;
    repositoryRelativePath: string;
    originalPath?: string;
    status: ExplorerGitFileMenuState["status"];
    staged?: boolean;
  },
  staged: boolean,
): GitFileDiffTarget {
  return {
    target: {
      repoPath: context.repoPath,
      filePath: context.repositoryRelativePath,
      ...(context.originalPath ? { originalPath: context.originalPath } : {}),
      untracked: context.status === "untracked",
      ...(staged ? { staged: true } : {}),
      ...(!staged && context.staged ? { hasStagedChanges: true } : {}),
    },
    fileKey: `${staged ? "staged" : "unstaged"}:${context.repositoryRelativePath}`,
  };
}

export interface ResolvedGitStatusFile {
  file: GitFile;
  /** Repository-relative path with forward slashes, ready for Git commands. */
  repositoryRelativePath: string;
}

/**
 * Finds the status entry for a repository-relative path, preferring the
 * explicit `repositoryRelativePath` over the possibly workspace-decorated
 * `path`, and normalizing Windows separators on both sides.
 */
export function findGitStatusFileForPath(
  files: readonly GitFile[],
  targetPath: string,
): ResolvedGitStatusFile | null {
  const normalizedTarget = toForwardSlashes(targetPath);
  for (const file of files) {
    const repositoryRelativePath = toForwardSlashes(file.repositoryRelativePath ?? file.path);
    if (repositoryRelativePath === normalizedTarget) {
      return { file, repositoryRelativePath };
    }
  }
  return null;
}

/**
 * Decides which Git actions make sense for a file entry. A file without a Git
 * change entry gets no menu at all. Partially staged files keep `Add` so an
 * explicit whole-file action includes the remaining worktree edits.
 */
export function getExplorerGitFileMenuCapabilities(
  state: ExplorerGitFileMenuState | null,
): ExplorerGitFileMenuCapabilities {
  if (!state) return { showDiff: false, add: false, commitFile: false };

  return {
    showDiff: true,
    add: state.canToggleStaging !== false && (!state.staged || state.worktree === true),
    commitFile: true,
  };
}

/**
 * The `Git` submenu shown for a file entry in the project tree. Returns an
 * empty list when no capability applies so callers can skip the submenu.
 */
export function buildGitFileContextMenuItems({
  labels,
  actions,
  icons,
  capabilities,
  disabled = false,
}: GitFileContextMenuOptions): MenuItem[] {
  const children: MenuItem[] = [];

  if (capabilities.showDiff) {
    children.push({
      id: "git-show-diff",
      label: labels.showDiff,
      icon: icons?.showDiff,
      disabled,
      onClick: actions.showDiff,
    });
  }

  if (capabilities.add) {
    children.push({
      id: "git-add",
      label: labels.add,
      icon: icons?.add,
      disabled,
      onClick: actions.add,
    });
  }

  if (capabilities.commitFile) {
    children.push({
      id: "git-commit-file",
      label: labels.commitFile,
      icon: icons?.commitFile,
      disabled,
      onClick: actions.commitFile,
    });
  }

  if (children.length === 0) return [];

  return [
    {
      id: "git-file",
      label: labels.submenu,
      icon: icons?.submenu,
      disabled,
      onClick: () => {},
      children,
    },
  ];
}
