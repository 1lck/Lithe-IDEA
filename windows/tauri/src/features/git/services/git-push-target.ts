import type { GitPushTargetChoice } from "../types/git.types";
import type {
  WorkspaceCommitPushTarget,
  WorkspaceCommitPushTargetQuestion,
} from "../types/git-workspace-commit.types";

/** Remote branch a choice updates: the same-named branch, or the upstream's own name. */
export const pushTargetRemoteBranch = (
  question: Pick<WorkspaceCommitPushTargetQuestion, "localBranch" | "upstreamBranch">,
  choice: GitPushTargetChoice,
): string => (choice === "publish" ? question.localBranch : question.upstreamBranch);

/**
 * Binds an answer to the exact remote and branch that was shown, so Core can tell
 * when the tracking configuration changed before the push and ask again.
 */
export const confirmPushTarget = (
  question: WorkspaceCommitPushTargetQuestion,
  choice: GitPushTargetChoice,
): WorkspaceCommitPushTarget => ({
  choice,
  remote: question.remote,
  remoteBranch: pushTargetRemoteBranch(question, choice),
});
