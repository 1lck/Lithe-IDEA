import type { MultiFileDiff } from "../types/git-diff.types";
import type { GitDiff, GitHunk } from "../types/git.types";
import { monacoDiffHunk } from "./monaco-diff-rows";

export interface DiffStagingContext {
  repoPath: string;
  isStaged: boolean;
}

export function workingTreeStagingContext(
  review: Pick<MultiFileDiff, "commitHash" | "repoPath">,
  sectionKey: string,
): DiffStagingContext | undefined {
  if (review.commitHash !== "working-tree" || !review.repoPath) return;
  if (!sectionKey.startsWith("staged:") && !sectionKey.startsWith("unstaged:")) return;
  return { repoPath: review.repoPath, isStaged: sectionKey.startsWith("staged:") };
}

type HunkOperation = (repoPath: string, hunk: GitHunk) => Promise<boolean>;
type ActionResult = "applied" | "failed" | "ignored";

/** One immutable host patch owns its actions until the next diff refresh. */
export function createMonacoDiffHunkActions(
  diff: GitDiff,
  context: DiffStagingContext | undefined,
  operations: { stage: HunkOperation; unstage: HunkOperation },
) {
  const action = context?.repoPath && !diff.is_truncated
    ? context.isStaged ? "unstage" : "stage" : null;
  let disposed = false;
  let pending = false;
  let applied = false;

  return {
    action,
    async apply(hunkID: string, requestedAction: string): Promise<ActionResult> {
      if (disposed || pending || applied || !action || !context || requestedAction !== action) return "ignored";
      const hunk = monacoDiffHunk(diff, hunkID);
      if (!hunk) return "ignored";
      pending = true;
      try {
        const success = await operations[action](context.repoPath, hunk);
        if (disposed) return "ignored";
        // The patch is stale after a successful mutation. Wait for the host's
        // Git change event to replace it before accepting another action.
        applied = success;
        return success ? "applied" : "failed";
      } catch {
        return disposed ? "ignored" : "failed";
      } finally {
        pending = false;
      }
    },
    dispose() { disposed = true; },
  };
}
