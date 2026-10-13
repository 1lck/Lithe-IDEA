import type { ReviewRow } from "@lithe/editor/diff-review";
import { diffWordsWithSpace } from "diff";
import type { CommitDiffKind } from "./commit-diff-chrome-geometry";

export interface IndependentChange {
  leftStart: number;
  leftEnd: number;
  rightStart: number;
  rightEnd: number;
  kind: CommitDiffKind;
}

export type CommitDiffLinePair = readonly [number, number];

/** IDEA SimpleDiffViewer boundary pairs; built once when the projection changes. */
export function commitDiffScrollAnchors(
  changes: readonly IndependentChange[],
  leftCount: number,
  rightCount: number,
): CommitDiffLinePair[] {
  return [
    [0, 0],
    ...changes.flatMap(
      (change) =>
        [
          [change.leftStart, change.rightStart],
          [change.leftEnd, change.rightEnd],
        ] as CommitDiffLinePair[],
    ),
    [leftCount, rightCount],
  ];
}

/** BaseSyncScrollable semantics: equal-line offset, clamp inside unequal blocks,
 * then resume at the next matching boundary. Never stretch a block proportionally.
 */
export function transferCommitDiffLine(
  anchors: readonly CommitDiffLinePair[],
  side: 0 | 1,
  line: number,
) {
  let low = 0,
    high = anchors.length;
  while (low < high) {
    const middle = (low + high) >>> 1;
    if (anchors[middle][side] < line) low = middle + 1;
    else high = middle;
  }
  const end = anchors[Math.min(low, anchors.length - 1)];
  const start = anchors[Math.max(0, low - 1)];
  const other = side === 0 ? 1 : 0;
  if (line === end[side]) return end[other];
  if (line > end[side]) return line - end[side] + end[other];
  return Math.min(start[other] + line - start[side], end[other]);
}

/** Git owns the edit script. Project each side without alignment spacer rows. */
export function planIndependentCommitDiff(
  rows: readonly ReviewRow[],
  collapse: boolean,
  expanded: ReadonlySet<string>,
) {
  const projected: ReviewRow[] = [];
  for (let index = 0; index < rows.length; ) {
    let end = index;
    while (end < rows.length && rows[end].kind === "context") end++;
    if (collapse && end - index >= 14) {
      const id = `fold-${rows[index].id}-${rows[end - 1].id}`;
      if (!expanded.has(id)) {
        projected.push(...rows.slice(index, index + 3));
        const text = `${end - index - 6} hidden lines`;
        projected.push({
          id,
          left: text,
          right: text,
          oldLine: null,
          newLine: null,
          kind: "information",
        });
        projected.push(...rows.slice(end - 3, end));
      } else projected.push(...rows.slice(index, end));
      index = end;
    } else if (end > index) {
      projected.push(...rows.slice(index, end));
      index = end;
    } else projected.push(rows[index++]);
  }
  const left: ReviewRow[] = [],
    right: ReviewRow[] = [],
    changes: IndependentChange[] = [];
  let pending: IndependentChange | undefined;
  for (const row of projected) {
    const changed = row.kind === "addition" || row.kind === "removal" || row.kind === "changed";
    if (changed && !pending)
      pending = {
        leftStart: left.length,
        leftEnd: left.length,
        rightStart: right.length,
        rightEnd: right.length,
        kind: "modified",
      };
    if (!changed && pending) {
      changes.push(pending);
      pending = undefined;
    }
    if (row.left !== null) left.push(row);
    if (row.right !== null) right.push(row);
    if (pending) {
      pending.leftEnd = left.length;
      pending.rightEnd = right.length;
    }
  }
  if (pending) changes.push(pending);
  for (const change of changes)
    change.kind =
      change.leftStart === change.leftEnd
        ? "inserted"
        : change.rightStart === change.rightEnd
          ? "deleted"
          : "modified";
  return { rows: projected, left, right, changes };
}

/** Reuse jsdiff's word engine, with explicit input/edit budgets for a read-only preview. */
export function commitDiffWordRanges(oldText: string, newText: string) {
  const left: Array<readonly [number, number, CommitDiffKind]> = [],
    right: Array<readonly [number, number, CommitDiffKind]> = [];
  if (oldText.length + newText.length > 8192) return { left, right };
  const parts = diffWordsWithSpace(oldText, newText, { maxEditLength: 512 });
  let oldOffset = 0,
    newOffset = 0;
  for (let index = 0; parts && index < parts.length; ) {
    const part = parts[index];
    if (!part.removed && !part.added) {
      oldOffset += part.value.length;
      newOffset += part.value.length;
      index++;
      continue;
    }
    const oldStart = oldOffset,
      newStart = newOffset;
    while (index < parts.length && (parts[index].removed || parts[index].added)) {
      const change = parts[index++];
      if (change.removed) oldOffset += change.value.length;
      else newOffset += change.value.length;
    }
    const kind =
      oldOffset === oldStart ? "inserted" : newOffset === newStart ? "deleted" : "modified";
    if (oldOffset > oldStart) left.push([oldStart, oldOffset, kind]);
    if (newOffset > newStart) right.push([newStart, newOffset, kind]);
  }
  return { left, right };
}
