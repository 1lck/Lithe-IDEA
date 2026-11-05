import type { GitUpdatePlan } from "@/features/git/api/git-update-plan-api";

type Strategy = "ffOnly" | "merge" | "rebase";

interface Preflight {
  upstream: string | null;
  ahead: number;
  behind: number;
  diverged: boolean;
  hasLocalChanges: boolean;
  configuredStrategy?: Strategy | null;
}

/**
 * Stand-in for Core's `git.updatePlan` in workflow tests. The rules belong to
 * Core (`git/update_plan.rs`); `git-update-plan-stub.test.ts` replays the shared
 * fixture `update-plan-v1.json` through this stub so it cannot drift from them.
 */
export function stubGitUpdatePlan(request: Record<string, any>): GitUpdatePlan {
  if (request.stage === "route") return route(request);
  if (request.stage === "defaultStrategy") {
    return {
      step: "defaultStrategy",
      strategy: defaultStrategy(request.preflight, request.fastForwardPossible),
    };
  }
  return inspect(request);
}

function defaultStrategy(preflight: Preflight, fastForwardPossible: boolean): Strategy {
  const configured = preflight.configuredStrategy;
  if (configured === "merge" || configured === "rebase") return configured;
  return fastForwardPossible ? "ffOnly" : "merge";
}

function route({ branch, worktrees }: Record<string, any>): GitUpdatePlan {
  if (!branch.upstream) return { step: "blocked", blocker: "noUpstream" };
  const owner = worktrees.find((worktree: any) => worktree.branch === branch.fullName);
  if (owner) {
    return {
      step: "inspect",
      checkout: owner.path,
      expectedBranch: branch.fullName,
      upstream: branch.upstream,
      interactive: owner.isCurrent,
    };
  }
  if (branch.isCurrent) {
    return {
      step: "inspect",
      checkout: null,
      expectedBranch: branch.fullName,
      upstream: branch.upstream,
      interactive: true,
    };
  }
  return { step: "fastForwardReference", expectedBranch: branch.fullName };
}

function inspect(request: Record<string, any>): GitUpdatePlan {
  const preflight: Preflight = request.preflight;
  const blocked = (blocker: any): GitUpdatePlan => ({ step: "blocked", blocker });
  const confirmation = request.confirmation;
  if (!request.explicitSource && !preflight.upstream) return blocked("noUpstream");
  if (confirmation) {
    const seen = confirmation.preflight;
    if (
      seen.upstream !== preflight.upstream ||
      seen.ahead !== preflight.ahead ||
      seen.behind !== preflight.behind ||
      seen.diverged !== preflight.diverged
    ) {
      return blocked("stateChanged");
    }
  }
  if (preflight.hasLocalChanges) return blocked("localChanges");
  if (!request.explicitSource && preflight.behind === 0 && !preflight.diverged) {
    return blocked("upToDate");
  }
  if (confirmation) return { step: "pull", strategy: confirmation.strategy };
  const resolved: Strategy = request.strategy ?? preflight.configuredStrategy ?? "ffOnly";
  if (resolved !== "ffOnly" || !preflight.diverged) return { step: "pull", strategy: resolved };
  return request.interactive ? { step: "chooseStrategy" } : blocked("notFastForward");
}
