import { updateBranch } from "../api/git-branches-api";
import { getGitPullWorkflow } from "../api/git-remotes-api";
import { readWorktrees } from "../api/git-worktrees-api";
import { emitGitChanged } from "../events/git-events";
import type { GitPullResult, GitReference } from "../types/git.types";
import { defaultPullStrategy } from "../utils/git-pull-selection";

/** IDEA updates checked-out branches in their worktree; other refs fast-forward in place. */
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
  const target = worktrees.find((worktree) => worktree.branch === reference.shortName);
  if (target) {
    return getGitPullWorkflow(target.path).run(target.path, {
      // Lithe's existing default is Merge. Another worktree only fast-forwards,
      // matching IDEA without switching the active repository or rewriting history.
      strategy: target.is_current ? defaultPullStrategy() : "ffOnly",
      allowStrategyPrompt: false,
      expectedBranch: reference.fullName,
      validateBranch: async () => {
        if (!isActive()) return false;
        const current = (await readWorktrees(target.path)).find((worktree) => worktree.is_current);
        return isActive() && !!current && !current.is_detached && current.branch === reference.shortName;
      },
      refresh: async () => {
        if (!target.is_current)
          emitGitChanged({
            repoPath,
            scopes: ["history", "refs", "remotes"],
            source: "update-branch",
          });
        await refresh();
      },
    });
  }
  try {
    await updateBranch(repoPath, reference);
    return { status: "branch-updated" };
  } finally {
    await refresh();
  }
}
