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

export function parseRemoteBranch(reference: GitReference): {
  remote: string;
  branch: string;
} | null {
  if (reference.kind !== "remote") return null;
  const [remote, ...branchParts] = reference.shortName.split("/");
  const branch = branchParts.join("/");
  return remote && branch && branch !== "HEAD" ? { remote, branch } : null;
}

export function suggestWorktreeBranchName(reference: GitReference): string {
  const remoteBranch = parseRemoteBranch(reference);
  const sourceName = remoteBranch?.branch ?? reference.shortName;
  return `${sourceName}-worktree`;
}
