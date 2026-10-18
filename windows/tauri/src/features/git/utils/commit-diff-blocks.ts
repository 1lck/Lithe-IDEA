import equal from "fast-deep-equal";
import type { GitDiff, GitHunk } from "../types/git.types";
import { parseDiffHunkRange } from "./git-diff-helpers";
import { gitGutterChangeHunk, type GitGutterChange } from "./git-gutter-changes";
import { monacoDiffRows } from "./monaco-diff-rows";
import { buildByteFaithfulHunk, buildFaithfulHunkFromRange } from "./lossy-rollback-patch";
import { planIndependentCommitDiff, type IndependentChange } from "./independent-commit-diff";

export interface CommitDiffBlock {
  id: string;
  checked: boolean;
  indeterminate: boolean;
  canToggle: boolean;
  canRollback: boolean;
  /** Unfolded model indices; presentation maps the stable row ID after folding. */
  leftStart: number;
  rightStart: number;
  wholeFile?: boolean;
  stage?: GitHunk;
  unstage?: GitHunk;
  rollback?: GitHunk;
}

export function commitDiffChangeID(
  plan: ReturnType<typeof planIndependentCommitDiff>, change: IndependentChange,
): string {
  return change.leftStart < change.leftEnd
    ? plan.left[change.leftStart].id : plan.right[change.rightStart].id;
}

/** Only complete, validated Git streams may supply index patches. Never use
 * folded display coordinates, an aligned spacer, or sparse context as a base. */
function projection(diff: GitDiff, rollbackOnly = false) {
  if (!diff.is_full_context || diff.is_truncated || diff.is_binary || diff.is_image
    || (diff.has_lossy_line_endings && !rollbackOnly)) return null;
  const headers = diff.lines.filter(line => line.line_type === "header");
  if (headers.length !== 1) return null;
  const range = parseDiffHunkRange(headers[0].content);
  if (!range) return null;
  const plan = planIndependentCommitDiff(monacoDiffRows(diff, { hideHunkHeaders: true }), false, new Set());
  if (plan.left.length !== range.oldCount || plan.right.length !== range.newCount
    || range.oldStart !== (range.oldCount ? 1 : 0)
    || range.newStart !== (range.newCount ? 1 : 0)) return null;
  return {
    plan,
    before: plan.left.map(row => row.left!),
    after: plan.right.map(row => row.right!),
  };
}

function edit(start: number, before: string[], after: string[]): GitGutterChange {
  return {
    originalStart: start + 1, originalEnd: start + before.length + 1,
    modifiedStart: start + 1, modifiedEnd: start + after.length + 1,
    originalLines: before, modifiedLines: after,
    kind: !before.length ? "added" : !after.length ? "deleted" : "modified",
  };
}

/** HEAD -> worktree owns visible blocks; HEAD -> index owns inclusion. A block
 * can contain only some staged lines, and earlier staged additions shift index
 * coordinates. Rebuild just its index span with the existing gutter patch builder. */
export function planCommitDiffBlocks(worktree: GitDiff, staged: GitDiff): CommitDiffBlock[] | null {
  const lossyRollbackEligible = Boolean(
    worktree.has_lossy_line_endings && worktree.writePatch && !worktree.is_renamed,
  );
  const visible = projection(worktree, lossyRollbackEligible);
  if (!visible || worktree.is_renamed) return null;
  if (worktree.is_new || worktree.is_deleted) {
    const indexed = staged.lines.length ? projection(staged) : null;
    const change = visible.plan.changes[0];
    if (!change || visible.plan.changes.length !== 1 || (staged.lines.length && !indexed)) return null;
    const checked = Boolean(indexed && equal(indexed.after, visible.after));
    return [{ id: commitDiffChangeID(visible.plan, change), checked,
      indeterminate: !checked && staged.lines.length > 0, canToggle: true,
      canRollback: false, wholeFile: true, leftStart: change.leftStart, rightStart: change.rightStart }];
  }
  // The staged projection feeds both toggle and rollback calculations; when
  // only rollback runs the byte-faithful channel, the staged side may use
  // the lossy projection for coordinate math — canToggle stays separately
  // gated and stage/unstage hunks are never built from lossy data.
  const indexed = staged.lines.length === 0
    ? { before: visible.before, after: visible.before, plan: { changes: [] as IndependentChange[] } }
    : projection(staged, lossyRollbackEligible);
  if (!indexed || !equal(indexed.before, visible.before)) return null;
  return visible.plan.changes.map(change => {
    let start = change.leftStart, end = change.leftEnd, overlapsBoundary = false;
    for (const prior of indexed.plan.changes) {
      // A staged insertion at a replacement's outer boundary can be an
      // index-only edit absent from this worktree block. Do not erase it.
      if (prior.leftStart === prior.leftEnd && prior.leftStart === change.leftStart
        && change.leftStart !== change.leftEnd) overlapsBoundary = true;
      const delta = prior.rightEnd - prior.rightStart - (prior.leftEnd - prior.leftStart);
      if (prior.leftEnd <= change.leftStart && prior.leftStart < change.leftStart) {
        start += delta; end += delta;
      } else if (prior.leftStart >= change.leftStart && prior.leftEnd <= change.leftEnd
        && (prior.leftStart < change.leftEnd || change.leftStart === change.leftEnd)) {
        end += delta;
      } else if (prior.leftStart < change.leftEnd && prior.leftEnd > change.leftStart) {
        overlapsBoundary = true;
      }
    }
    const before = visible.before.slice(change.leftStart, change.leftEnd);
    const after = visible.after.slice(change.rightStart, change.rightEnd);
    const indexLines = indexed.after.slice(start, end);
    const checked = equal(indexLines, after);
    const indeterminate = !checked && !equal(indexLines, before);
    const revertedIndex = [...indexed.after.slice(0, start), ...before, ...indexed.after.slice(end)];
    const rollbackBase = [...visible.after.slice(0, change.rightStart), ...indexLines,
      ...visible.after.slice(change.rightEnd)];
    // Find the full range of unstaged lines within this block: every line
    // where index differs from worktree. This maps HEAD display coordinates
    // to index/worktree coordinates (P1) and handles partially staged blocks
    // (P2) and pure additions with empty old side (P4).
    let unstagedIndexStart = -1;
    let unstagedIndexEnd = -1;
    let unstagedWorktreeStart = -1;
    let unstagedWorktreeEnd = -1;
    if (end === start) {
      // Pure addition: no index-side lines exist; the insertion boundary is
      // the position between index lines where the worktree lines appear.
      unstagedIndexStart = start;
      unstagedIndexEnd = start;
      unstagedWorktreeStart = change.rightStart;
      unstagedWorktreeEnd = change.rightEnd;
    } else {
      for (let i = 0; i < end - start; i++) {
        const indexLine = indexed.after[start + i];
        const worktreeLine = visible.after[change.rightStart + i];
        if (indexLine !== worktreeLine) {
          if (unstagedIndexStart === -1) {
            unstagedIndexStart = start + i;
            unstagedWorktreeStart = change.rightStart + i;
          }
          unstagedIndexEnd = start + i;
          unstagedWorktreeEnd = change.rightStart + i;
        }
      }
    }
    const block: CommitDiffBlock = {
      id: commitDiffChangeID(visible.plan, change), checked, indeterminate,
      canToggle: !overlapsBoundary && !worktree.has_lossy_line_endings,
      // Rollback restores this block to the index, preserving included content.
      // With writePatch the hunk carries original bytes (CR, EOF markers).
      canRollback: !overlapsBoundary && !checked,
      leftStart: change.leftStart, rightStart: change.rightStart,
      stage: gitGutterChangeHunk(worktree.file_path, indexed.after, edit(start, indexLines, after)),
      unstage: gitGutterChangeHunk(worktree.file_path, revertedIndex, edit(start, before, indexLines)),
      // Byte-faithful rollback passes the full unstaged range and builds
      // directly from the raw patch's changed lines within that range —
      // no contiguity requirement, so a block's changes can be isolated
      // even when adjacent to another block's changes in the raw patch.
      rollback: worktree.writePatch && unstagedIndexStart >= 0
        ? (buildFaithfulHunkFromRange(
            worktree,
            unstagedIndexStart + 1,
            unstagedWorktreeStart + 1,
            unstagedIndexEnd + 1,
            unstagedWorktreeEnd + 1,
          ) ?? buildByteFaithfulHunk(
            worktree,
            unstagedIndexStart + 1,
            unstagedWorktreeStart + 1,
            unstagedIndexEnd + 1,
            unstagedWorktreeEnd + 1,
          ) ?? undefined)
        : (!worktree.has_lossy_line_endings
          ? gitGutterChangeHunk(worktree.file_path, rollbackBase, edit(change.rightStart, indexLines, after))
          : undefined),
    };
    block.canRollback = block.canRollback && block.rollback !== undefined;
    return block;
  });
}
