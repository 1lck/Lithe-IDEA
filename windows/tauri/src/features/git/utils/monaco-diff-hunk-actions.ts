import type { MultiFileDiff } from "../types/git-diff.types";
import type { GitDiff, GitHunk } from "../types/git.types";
import { monacoDiffHunk } from "./monaco-diff-rows";

export interface DiffStagingContext {
  repoPath: string;
  isStaged: boolean;
  /**
   * The review reloads itself after a Git change, so a discarded block
   * disappears instead of leaving a stale patch on screen. Only unstaged
   * reviews with a working-tree refresh target offer discard.
   */
  canDiscard?: boolean;
}

export function workingTreeStagingContext(
  review: Pick<MultiFileDiff, "commitHash" | "repoPath" | "workingTreeTargets">,
  sectionKey: string,
): DiffStagingContext | undefined {
  if (review.commitHash !== "working-tree" || !review.repoPath) return;
  if (!sectionKey.startsWith("staged:") && !sectionKey.startsWith("unstaged:")) return;
  const isStaged = sectionKey.startsWith("staged:");
  const target = review.workingTreeTargets?.[sectionKey];
  const canDiscard = !isStaged && !!target && !target.staged && !target.untracked
    && !target.hasStagedChanges;
  return { repoPath: review.repoPath, isStaged, ...(canDiscard ? { canDiscard: true } : {}) };
}

type HunkOperation = (repoPath: string, hunk: GitHunk) => Promise<boolean>;
export type HunkActionID = "stage" | "unstage" | "discard";
type ActionResult = "applied" | "failed" | "cancelled" | "ignored";

export interface MonacoDiffHunkOperations {
  stage: HunkOperation;
  unstage: HunkOperation;
  /** Reverse-applies the block to the working tree. */
  discard?: HunkOperation;
  /** Asks the user before a destructive write; false cancels without writing. */
  confirmDiscard?: (hunk: GitHunk) => Promise<boolean>;
}

/** Discard rewrites working-tree content. New and deleted files have no
 * block-level inverse: reversing the only hunk of an untracked file leaves an
 * empty file behind instead of removing it. Renames come from the index and
 * are never part of an unstaged review; they are excluded defensively. */
function canDiscardDiff(diff: GitDiff): boolean {
  return !diff.is_new && !diff.is_deleted && !diff.is_renamed && !diff.is_binary && !diff.is_image;
}

/** One immutable host patch owns its actions until the next diff refresh. */
export function createMonacoDiffHunkActions(
  diff: GitDiff,
  context: DiffStagingContext | undefined,
  operations: MonacoDiffHunkOperations,
) {
  const writable = Boolean(context?.repoPath) && !diff.is_truncated;
  const action: "stage" | "unstage" | null = writable && context
    ? context.isStaged ? "unstage" : "stage" : null;
  const discardEnabled = writable && !!context && !context.isStaged && context.canDiscard === true
    && !!operations.discard && !!operations.confirmDiscard && canDiscardDiff(diff);
  const actions: readonly HunkActionID[] = action
    ? discardEnabled ? [action, "discard"] : [action] : [];
  let disposed = false;
  let pending = false;
  let applied = false;

  return {
    action,
    actions,
    async apply(hunkID: string, requestedAction: string): Promise<ActionResult> {
      if (disposed || pending || applied || !context
        || !(actions as readonly string[]).includes(requestedAction)) return "ignored";
      const hunk = monacoDiffHunk(diff, hunkID);
      if (!hunk) return "ignored";
      const requested = requestedAction as HunkActionID;
      // Pending also covers the confirmation dialog, so a second click cannot
      // queue another destructive write behind it.
      pending = true;
      try {
        if (requested === "discard") {
          const confirmed = await operations.confirmDiscard!(hunk);
          // A refresh while the dialog was open replaced this patch; its
          // identity no longer describes the file, so the answer is moot.
          if (disposed) return "ignored";
          if (!confirmed) return "cancelled";
        }
        const operation = requested === "discard" ? operations.discard! : operations[requested];
        const success = await operation(context.repoPath, hunk);
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
