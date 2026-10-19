import equal from "fast-deep-equal";
import type { GitDiff, GitHunk } from "../types/git.types";
import { parseDiffHunkRange } from "./git-diff-helpers";
import { gitGutterChangeHunk, type GitGutterChange } from "./git-gutter-changes";
import { monacoDiffRows } from "./monaco-diff-rows";
import { buildByteFaithfulHunk, buildFaithfulHunkFromRange, parseRawPatchLines } from "./lossy-rollback-patch";
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
    // Display-stripped text comparison loses EOF/CRLF information; for lossy
    // diffs a pure newline-only change would falsely read as already staged.
    // When the writePatch is available, its changed lines within this block's
    // span are the authoritative answer: no changes means fully included.
    let checked = equal(indexLines, after);
    if (checked && worktree.has_lossy_line_endings && worktree.writePatch) {
      const rawChanged = parseRawPatchLines(worktree.writePatch).some(line => {
        if (line.isEofMarker || (line.prefix !== "+" && line.prefix !== "-")) return false;
        const oldOk = line.oldLine !== null && line.oldLine >= start + 1 && line.oldLine <= end;
        const newOk = line.newLine !== null
          && line.newLine >= change.rightStart + 1 && line.newLine <= change.rightEnd;
        return oldOk || newOk;
      });
      // Raw patch still reports changes inside this block: not fully included.
      if (rawChanged) checked = false;
    }
    const indeterminate = !checked && !equal(indexLines, before);
    const revertedIndex = [...indexed.after.slice(0, start), ...before, ...indexed.after.slice(end)];
    const rollbackBase = [...visible.after.slice(0, change.rightStart), ...indexLines,
      ...visible.after.slice(change.rightEnd)];
    // Byte-faithful rollback passes the block's full index-side and
    // worktree-side spans directly to the range builder — no line-by-line
    // comparison needed. The builder collects all raw-patch changed lines
    // within these spans. Zero-based slice indices convert to one-based
    // inclusive: [start, end) → [start+1, end]; for the new side,
    // rightEnd (not +1) yields an empty range for pure deletions.
    const block: CommitDiffBlock = {
      id: commitDiffChangeID(visible.plan, change), checked, indeterminate,
      canToggle: !overlapsBoundary && !worktree.has_lossy_line_endings,
      canRollback: !overlapsBoundary && !checked,
      leftStart: change.leftStart, rightStart: change.rightStart,
      stage: gitGutterChangeHunk(worktree.file_path, indexed.after, edit(start, indexLines, after)),
      unstage: gitGutterChangeHunk(worktree.file_path, revertedIndex, edit(start, before, indexLines)),
      rollback: worktree.writePatch
        ? (buildFaithfulHunkFromRange(
            worktree,
            start + 1,
            change.rightStart + 1,
            end,
            change.rightEnd,
          ) ?? buildByteFaithfulHunk(
            worktree,
            start + 1,
            change.rightStart + 1,
            end,
            change.rightEnd,
          ) ?? undefined)
        : (!worktree.has_lossy_line_endings
          ? gitGutterChangeHunk(worktree.file_path, rollbackBase, edit(change.rightStart, indexLines, after))
          : undefined),
    };
    block.canRollback = block.canRollback && block.rollback !== undefined;
    return block;
  });
}
