import type { ReactNode } from "react";
import type { MenuItem } from "@/ui/dropdown";

/** Git status slice the per-file context menu decisions depend on. */
export interface ExplorerGitFileMenuState {
  status: "modified" | "added" | "deleted" | "untracked" | "renamed";
  staged: boolean;
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

/**
 * Decides which Git actions make sense for a file entry. A file without a Git
 * change entry gets no menu at all; an already staged entry hides `Add` because
 * staging it again is a no-op.
 */
export function getExplorerGitFileMenuCapabilities(
  state: ExplorerGitFileMenuState | null,
): ExplorerGitFileMenuCapabilities {
  if (!state) return { showDiff: false, add: false, commitFile: false };

  return {
    showDiff: true,
    add: !state.staged,
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
