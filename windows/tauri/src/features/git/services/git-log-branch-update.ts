import { updateBranch } from "../api/git-branches-api";
import { getGitPullWorkflow } from "../api/git-remotes-api";
import { planGitBranchUpdate } from "../api/git-update-plan-api";
import { readWorktrees } from "../api/git-worktrees-api";
import { emitGitChanged } from "../events/git-events";
import type { GitPullResult, GitReference } from "../types/git.types";

/**
 * IDEA updates checked-out branches in their worktree; other refs fast-forward in place.
 * Core's `git.updatePlan` decides where each branch is updated and which gates apply.
 */
export async function updateGitLogBranch(
  repoPath: string,
  reference: GitReference,
  refresh: () => Promise<void>,
  isActive: () => boolean = () => true,
): Promise<GitPullResult | { status: "branch-updated" }> {
  if (reference.kind !== "local" || !reference.upstreamShortName) {
    throw new Error("The selected local branch has no upstream");
  }
  const worktrees = await readWorktrees(repoPath);
  // Repository discovery can finish after the Log has changed workspace or closed.
  if (!isActive()) return { status: "cancelled" };
  const route = await planGitBranchUpdate(
    {
      fullName: reference.fullName,
      upstream: reference.upstreamShortName,
      isCurrent: reference.isCurrent,
    },
    worktrees,
  );
  if (route.step === "blocked") {
    throw new Error("The selected local branch has no upstream");
  }
  if (route.step === "inspect") {
    const checkout = route.checkout ?? repoPath;
    const isCurrentCheckout = route.checkout === null || worktrees.some(
      (worktree) => worktree.path === route.checkout && worktree.is_current,
    );
    return getGitPullWorkflow(checkout).run(checkout, {
      // Only the active worktree may ask for a strategy; another worktree
      // never switches the active repository or rewrites history.
      interactive: route.interactive,
      expectedBranch: route.expectedBranch,
      validateBranch: async () => {
        if (!isActive()) return false;
        const current = (await readWorktrees(checkout)).find((worktree) => worktree.is_current);
        return (
          isActive() &&
          !!current &&
          !current.is_detached &&
          `refs/heads/${current.branch}` === route.expectedBranch
        );
      },
      refresh: async () => {
        if (!isCurrentCheckout)
          emitGitChanged({
            repoPath,
            scopes: ["history", "refs", "remotes"],
            source: "update-branch",
          });
        await refresh();
      },
    });
  }
  if (route.step !== "fastForwardReference") throw new Error("Invalid Git update plan");
  try {
    await updateBranch(repoPath, reference);
    return { status: "branch-updated" };
  } finally {
    await refresh();
  }
}
