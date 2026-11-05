import { invoke as tauriInvoke } from "@/platform/tauri-core";
import type { GitPullPreflight, GitWorktree, PullStrategy } from "../types/git.types";

/** Why a branch Update or Pull stops; the UI localizes it. */
export type GitUpdateBlocker =
  | "noUpstream"
  | "localChanges"
  | "upToDate"
  | "notFastForward"
  | "stateChanged";

/** The next step `git.updatePlan` asks the host to run. */
export type GitUpdatePlan =
  | { step: "blocked"; blocker: GitUpdateBlocker }
  | { step: "fastForwardReference"; expectedBranch: string }
  | {
      step: "inspect";
      /** Worktree to fetch and pull in; `null` means the repository of the request. */
      checkout: string | null;
      expectedBranch: string;
      upstream: string;
      /** Only the current worktree may ask the user for a strategy. */
      interactive: boolean;
    }
  | { step: "chooseStrategy" }
  | { step: "pull"; strategy: PullStrategy }
  | { step: "defaultStrategy"; strategy: PullStrategy };

// Note: shared/fixtures/git/update-plan-v1.json defines every rule below.

const plan = (request: Record<string, unknown>) =>
  tauriInvoke<GitUpdatePlan>("git.updatePlan", request);

/**
 * Routes the Update of one local branch: which worktree pulls it, or whether
 * it fast-forwards in place. Worktree branches are short names.
 */
export function planGitBranchUpdate(
  branch: { fullName: string; upstream?: string | null; isCurrent: boolean },
  worktrees: readonly GitWorktree[],
): Promise<GitUpdatePlan> {
  return plan({
    stage: "route",
    branch: {
      fullName: branch.fullName,
      upstream: branch.upstream ?? null,
      isCurrent: branch.isCurrent,
    },
    worktrees: worktrees.map((worktree) => ({
      path: worktree.path,
      branch: worktree.is_detached || !worktree.branch ? null : `refs/heads/${worktree.branch}`,
      isCurrent: worktree.is_current,
    })),
  });
}

/** Gates a pull in one checkout after Fetch and `git.pullPreflight`. */
export function planGitPullInspection(input: {
  preflight: GitPullPreflight;
  interactive: boolean;
  explicitSource: boolean;
  strategy?: PullStrategy;
}): Promise<GitUpdatePlan> {
  return plan({
    stage: "inspect",
    preflight: input.preflight,
    interactive: input.interactive,
    explicitSource: input.explicitSource,
    ...(input.strategy ? { strategy: input.strategy } : {}),
  });
}

/** The strategy the Pull dialog preselects. */
export async function defaultGitPullStrategy(
  preflight: GitPullPreflight,
  fastForwardPossible: boolean,
): Promise<PullStrategy> {
  const result = await plan({ stage: "defaultStrategy", preflight, fastForwardPossible });
  if (result.step !== "defaultStrategy") throw new Error("Invalid Git update plan");
  return result.strategy;
}
