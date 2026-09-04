import type { GitReference } from "../types/git.types";

export type GitReferenceAction =
  | "checkout"
  | "createBranch"
  | "checkoutAndRebase"
  | "checkoutAndUpdate"
  | "compareWithCurrent"
  | "diffWithWorkingTree"
  | "rebaseCurrentOnto"
  | "mergeIntoCurrent"
  | "pullRebaseIntoCurrent"
  | "pullMergeIntoCurrent"
  | "createWorktree"
  | "update"
  | "push"
  | "tracking"
  | "rename"
  | "deleteLocal"
  | "deleteRemote";

const CURRENT_BRANCH_ACTIONS: GitReferenceAction[] = [
  "createBranch",
  "diffWithWorkingTree",
  "createWorktree",
  "update",
  "push",
  "tracking",
  "rename",
];

const OTHER_LOCAL_BRANCH_ACTIONS: GitReferenceAction[] = [
  "checkout",
  "createBranch",
  "checkoutAndRebase",
  "checkoutAndUpdate",
  "compareWithCurrent",
  "diffWithWorkingTree",
  "rebaseCurrentOnto",
  "mergeIntoCurrent",
  "createWorktree",
  "update",
  "push",
  "rename",
  "deleteLocal",
];

const REMOTE_BRANCH_ACTIONS: GitReferenceAction[] = [
  "checkout",
  "createBranch",
  "checkoutAndRebase",
  "compareWithCurrent",
  "diffWithWorkingTree",
  "rebaseCurrentOnto",
  "mergeIntoCurrent",
  "createWorktree",
  "pullRebaseIntoCurrent",
  "pullMergeIntoCurrent",
  "deleteRemote",
];

const TAG_ACTIONS: GitReferenceAction[] = [
  "checkout",
  "createBranch",
  "compareWithCurrent",
  "diffWithWorkingTree",
];

export function getGitReferenceActions(reference: GitReference): GitReferenceAction[] {
  if (reference.kind === "local") {
    return reference.isCurrent ? CURRENT_BRANCH_ACTIONS : OTHER_LOCAL_BRANCH_ACTIONS;
  }
  if (reference.kind === "remote") return REMOTE_BRANCH_ACTIONS;
  return TAG_ACTIONS;
}

export interface GitReferenceToolbarState {
  canCreateBranch: boolean;
  canUpdateSelected: boolean;
  canDeleteBranch: boolean;
  canCompareWithCurrent: boolean;
  canFetch: boolean;
  canToggleMark: boolean;
}

export function getGitReferenceToolbarState(
  selectedReference: GitReference | null,
  currentReference: GitReference | null,
  isMutating: boolean,
): GitReferenceToolbarState {
  const selectedLocalBranch = selectedReference?.kind === "local" ? selectedReference : null;
  const canUpdateSelected = Boolean(
    selectedLocalBranch &&
      (selectedLocalBranch.isCurrent ||
        (selectedLocalBranch.upstreamShortName && (selectedLocalBranch.behind ?? 0) > 0)),
  );
  return {
    canCreateBranch: !isMutating && Boolean(selectedReference ?? currentReference),
    canUpdateSelected: !isMutating && canUpdateSelected,
    canDeleteBranch: !isMutating && Boolean(selectedLocalBranch && !selectedLocalBranch.isCurrent),
    canCompareWithCurrent: !isMutating && Boolean(selectedReference && !selectedReference.isCurrent),
    canFetch: !isMutating,
    canToggleMark: Boolean(selectedLocalBranch),
  };
}

export function suggestWorktreeBranchName(reference: GitReference): string {
  const sourceParts = reference.shortName.split("/").filter(Boolean);
  const sourceName = sourceParts[sourceParts.length - 1] ?? "worktree";
  return `${sourceName}-worktree`;
}
