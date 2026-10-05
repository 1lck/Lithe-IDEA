import equal from "fast-deep-equal";
import type { GitDiff, GitHunk } from "../types/git.types";
import { parseDiffHunkRange } from "./git-diff-helpers";
import { gitGutterChangeHunk, type GitGutterChange } from "./git-gutter-changes";
import { monacoDiffRows } from "./monaco-diff-rows";
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
function projection(diff: GitDiff) {
  if (!diff.is_full_context || diff.is_truncated || diff.is_binary || diff.is_image
    || diff.has_lossy_line_endings) return null;
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
  const visible = projection(worktree);
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
  const indexed = staged.lines.length === 0
    ? { before: visible.before, after: visible.before, plan: { changes: [] as IndependentChange[] } }
    : projection(staged);
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
    return {
      id: commitDiffChangeID(visible.plan, change), checked, indeterminate,
      canToggle: !overlapsBoundary,
      // Rollback restores this block to the index, preserving included content.
      canRollback: !overlapsBoundary && !checked,
      leftStart: change.leftStart, rightStart: change.rightStart,
      stage: gitGutterChangeHunk(worktree.file_path, indexed.after, edit(start, indexLines, after)),
      unstage: gitGutterChangeHunk(worktree.file_path, revertedIndex, edit(start, before, indexLines)),
      rollback: gitGutterChangeHunk(worktree.file_path, rollbackBase,
        edit(change.rightStart, indexLines, after)),
    };
  });
}
