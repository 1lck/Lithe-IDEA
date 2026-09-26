import type { ReactNode } from "react";
import type { MenuItem } from "@/ui/dropdown";

export interface GitContextMenuLabels {
  submenu: string;
  openGitLog: string;
  fetch: string;
  pull: string;
  push: string;
  newBranch: string;
}

export interface GitContextMenuActions {
  openGitLog: () => void;
  fetch: () => void;
  pull: () => void;
  push: () => void;
  newBranch: () => void;
}

export interface GitContextMenuIcons {
  submenu?: ReactNode;
  openGitLog?: ReactNode;
  fetch?: ReactNode;
  pull?: ReactNode;
  push?: ReactNode;
  newBranch?: ReactNode;
}

export interface GitContextMenuOptions {
  labels: GitContextMenuLabels;
  actions: GitContextMenuActions;
  icons?: GitContextMenuIcons;
  disabled?: boolean;
}

/** The `Git` submenu shown for a repository-root directory in the project tree. */
export function buildGitRepositoryContextMenuItems({
  labels,
  actions,
  icons,
  disabled = false,
}: GitContextMenuOptions): MenuItem[] {
  return [
    {
      id: "git",
      label: labels.submenu,
      icon: icons?.submenu,
      disabled,
      onClick: () => {},
      children: [
        {
          id: "git-open-log",
          label: labels.openGitLog,
          icon: icons?.openGitLog,
          disabled,
          onClick: actions.openGitLog,
        },
        {
          id: "git-fetch",
          label: labels.fetch,
          icon: icons?.fetch,
          disabled,
          onClick: actions.fetch,
        },
        {
          id: "git-pull",
          label: labels.pull,
          icon: icons?.pull,
          disabled,
          onClick: actions.pull,
        },
        {
          id: "git-push",
          label: labels.push,
          icon: icons?.push,
          disabled,
          onClick: actions.push,
        },
        {
          id: "git-new-branch",
          label: labels.newBranch,
          icon: icons?.newBranch,
          disabled,
          onClick: actions.newBranch,
        },
      ],
    },
  ];
}
