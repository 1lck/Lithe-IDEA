import { useEffect, useState } from "react";
import { invoke } from "@/platform/tauri-core";
import type { GitHistoryRewriteCommit } from "../types/git-history-rewrite.types";
import type { GitRebaseStep } from "../types/git-rebase.types";

/** What the plan editor presents and submits for one draft (`git.rebasePlanPreview`). */
export interface GitRebasePlanPreview {
  /** First problem the user must fix; `null` when the plan can start. */
  issue: {
    code: "missingPrecedingCommit" | "emptyRewordMessage" | "emptySquashMessage" | "invalidMessage";
    hash: string | null;
  } | null;
  /** Draft rows with the message the editor shows for each. */
  steps: Array<{ hash: string; action: GitRebaseStep["action"]; message: string }>;
  /** Exact steps for `git.rebaseStart`. */
  startSteps: GitRebaseStep[];
  outputCommitCount: number;
}

/**
 * Validates a rebase draft and derives its messages in Core, with the rules the
 * start command applies. Plan messages are explicit user edits; predicted squash
 * text stays presentation-only.
 */
export function loadGitRebasePlanPreview(
  steps: readonly GitRebaseStep[],
  commits: readonly GitHistoryRewriteCommit[],
): Promise<GitRebasePlanPreview> {
  return invoke<GitRebasePlanPreview>("git.rebasePlanPreview", {
    commits: commits.map(({ hash, message }) => ({ hash, message })),
    steps,
  });
}

/** Core's preview for the current draft; `null` while it loads, after a rejected draft, or without commits. */
export function useGitRebasePlanPreview(
  steps: readonly GitRebaseStep[],
  commits: readonly GitHistoryRewriteCommit[] | undefined,
): GitRebasePlanPreview | null {
  const [snapshot, setSnapshot] = useState<{
    steps: readonly GitRebaseStep[];
    plan: GitRebasePlanPreview;
  } | null>(null);
  useEffect(() => {
    if (!commits || commits.length === 0) return;
    let current = true;
    loadGitRebasePlanPreview(steps, commits)
      .then((plan) => {
        if (current) setSnapshot({ steps, plan });
      })
      .catch((error) => {
        if (current) console.error("Failed to preview the rebase plan:", error);
      });
    return () => {
      current = false;
    };
  }, [steps, commits]);
  return snapshot?.steps === steps ? snapshot.plan : null;
}
