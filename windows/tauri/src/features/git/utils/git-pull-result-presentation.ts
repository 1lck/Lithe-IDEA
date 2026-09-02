import type { GitPullResult } from "../types/git.types";

type Translate = (key: string, values?: Record<string, string | number>) => string;

export interface GitPullResultPresentation {
  message: string;
  tone: "success" | "info" | "warning" | "error";
}

export function getGitPullResultPresentation(
  result: GitPullResult,
  translate: Translate,
): GitPullResultPresentation | null {
  switch (result.status) {
    case "duplicate":
    case "cancelled":
      return null;
    case "pulled":
      return {
        message: translate(
          result.strategy === "merge"
            ? "git.pullResult.merged"
            : result.strategy === "rebase"
              ? "git.pullResult.rebased"
              : "git.pullResult.pulled",
        ),
        tone: "success",
      };
    case "conflict":
      return {
        message: translate(
          result.operation.kind === "merge"
            ? "git.pullResult.mergeConflict"
            : "git.pullResult.rebaseConflict",
        ),
        tone: "warning",
      };
    case "blocked": {
      const keys = {
        "no-upstream": "git.pullResult.noUpstream",
        dirty: "git.pullResult.dirty",
        "up-to-date": "git.pullResult.upToDate",
        "state-changed": "git.pullResult.stateChanged",
      } as const;
      return {
        message: translate(keys[result.reason]),
        tone: result.reason === "up-to-date" ? "info" : "warning",
      };
    }
    case "failed": {
      const keys = {
        fetch: "git.pullResult.fetchFailed",
        preflight: "git.pullResult.preflightFailed",
        pull: "git.pullResult.pullFailed",
      } as const;
      const fallbacks = {
        fetch: "git.pullResult.remoteUpdateFailed",
        preflight: "git.pullResult.inspectBranchFailed",
        pull: "git.pullResult.gitRejectedPull",
      } as const;
      return {
        message: translate(keys[result.stage], {
          error: result.error || translate(fallbacks[result.stage]),
        }),
        tone: "error",
      };
    }
  }
}
