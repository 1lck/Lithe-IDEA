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
type ActionResult = "applied" | "failed" | "ignored" | "cancelled" | "stale";

export interface MonacoDiffHunkOperations {
  stage: HunkOperation;
  unstage: HunkOperation;
  /** Reverse-applies the block to the working tree. */
  discard?: HunkOperation;
  /** Pre-write staleness probe for zero-context hunks (`rawPatch`): resolves
   * false when the patch the hunk was sliced from no longer matches the
   * repository. `git apply --unidiff-zero` has no surrounding context to
   * reject a relocated change, so the surface verifies currency itself.
   * Ordinary hunks keep their context lines and rely on git apply. */
  validate?: (hunk: GitHunk) => Promise<boolean>;
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
  // Stage/unstage keep the lossy protection unconditionally: their write
  // hunks come from display lines which lack original bytes.
  const toggleAction: "stage" | "unstage" | null = writable && !diff.has_lossy_line_endings && context
    ? context.isStaged ? "unstage" : "stage" : null;
  // Discard rides the byte-faithful channel: monacoDiffHunk slices from
  // writePatch when available, so lossy files can discard with original
  // bytes. Without writePatch, lossy files keep the protective fallback.
  const discardEnabled = writable && !!context && !context.isStaged && context.canDiscard === true
    && !!operations.discard && canDiscardDiff(diff)
    && (!diff.has_lossy_line_endings || Boolean(diff.writePatch));
  const actions: readonly HunkActionID[] = toggleAction
    ? discardEnabled ? [toggleAction, "discard"] : [toggleAction]
    : discardEnabled ? ["discard"] : [];
  let disposed = false;
  let pending = false;
  let applied = false;

  return {
    action: toggleAction,
    actions,
    async apply(hunkID: string, requestedAction: string): Promise<ActionResult> {
      if (disposed || pending || applied || !context
        || !(actions as readonly string[]).includes(requestedAction)) return "ignored";
      const hunk = monacoDiffHunk(diff, hunkID);
      if (!hunk) return "ignored";
      const requested = requestedAction as HunkActionID;
      // Block arrows are direct actions, separate from file/repository discard
      // confirmation. Keep duplicate clicks locked until the write completes.
      pending = true;
      try {
        // A zero-context discard has no git-apply context check, so it writes
        // only after the probe confirms its source patch is still current. A
        // failed or missing probe refuses rather than risk the wrong lines.
        if (requested === "discard" && hunk.rawPatch) {
          const current = operations.validate ? await operations.validate(hunk) : false;
          if (disposed) return "ignored";
          if (!current) return "stale";
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
