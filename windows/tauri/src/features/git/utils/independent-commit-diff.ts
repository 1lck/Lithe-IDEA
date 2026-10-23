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

/** A painted sub-block of one Git change. IDEA splits a changed line block by
 * its word comparison (`ComparisonManagerImpl.createInnerWordFragments` ->
 * `ByWord.compareAndSplit` -> `LineFragmentSplitter`), so lines that exist only
 * on one side keep their inserted/deleted color while similar lines stay
 * modified. Git remains the change script and the staging owner: the split is
 * display-only and never creates new block actions or differences. */
export interface IndependentDisplayChange extends IndependentChange {
  /** The Git change that owns this block; navigation and staging use it. */
  change: IndependentChange;
  /** First painted block of its Git change; hosts the block action controls. */
  first: boolean;
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

/** Pairing budget for the display-only line alignment. Git can report a whole
 * renumbered file as one changed block; keep the work bounded and fall back to
 * the un-split change beyond it. */
const DISPLAY_ALIGNMENT_MAX_CELLS = 250_000;
/** Token comparisons per alignment; very long lines would otherwise multiply
 * the per-cell token scan beyond the useful preview budget. */
const DISPLAY_ALIGNMENT_MAX_TOKEN_WORK = 4_000_000;
/** Missing a line costs less than keeping a clearly wrong pair, but more than
 * any real similarity — JSON lines differing in one value still pair up. */
const DISPLAY_ALIGNMENT_GAP = 0.45;

/** IDEA's inline comparison ignores punctuation and separates continuous
 * scripts per code point; tokens only feed the display similarity score. */
function similarityTokens(text: string): string[] {
  return text.match(/[A-Za-z0-9_]+|[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}]/gu) ?? [];
}

function tokenCounts(tokens: readonly string[]): Map<string, number> {
  const counts = new Map<string, number>();
  for (const token of tokens) counts.set(token, (counts.get(token) ?? 0) + 1);
  return counts;
}

/** 2 * shared / total, so identical lines score 1 and unrelated lines 0. */
function lineSimilarity(
  left: ReadonlyMap<string, number>,
  right: ReadonlyMap<string, number>,
  leftSize: number,
  rightSize: number,
): number {
  const [small, large] = left.size <= right.size ? [left, right] : [right, left];
  let shared = 0;
  for (const [token, count] of small) {
    const other = large.get(token);
    if (other) shared += Math.min(count, other);
  }
  return (2 * shared) / (leftSize + rightSize || 1);
}

interface AlignedLine {
  left: number | null;
  right: number | null;
  /** The pair shares at least one token, i.e. IDEA's "equal words" inside a
   * changed line block. */
  similar: boolean;
}

/** Align the lines of one Git change, returning `null` instead of a pair for
 * lines that have no counterpart on the other side. */
function alignChangeLines(left: readonly string[], right: readonly string[]): AlignedLine[] | null {
  const leftTokens = left.map(similarityTokens);
  const rightTokens = right.map(similarityTokens);
  const rows = left.length,
    columns = right.length;
  const largestTokenLine = (tokens: readonly string[][]) =>
    tokens.reduce((largest, line) => Math.max(largest, line.length), 1);
  if (rows * columns * Math.min(largestTokenLine(leftTokens), largestTokenLine(rightTokens))
    > DISPLAY_ALIGNMENT_MAX_TOKEN_WORK) return null;
  const leftCounts = leftTokens.map(tokenCounts);
  const rightCounts = rightTokens.map(tokenCounts);
  const width = columns + 1;
  const directions = new Uint8Array((rows + 1) * width);
  let previous = new Float64Array(width);
  let current = new Float64Array(width);
  for (let column = 1; column <= columns; column++) previous[column] = previous[column - 1] - DISPLAY_ALIGNMENT_GAP;
  for (let row = 1; row <= rows; row++) {
    current[0] = previous[0] - DISPLAY_ALIGNMENT_GAP;
    for (let column = 1; column <= columns; column++) {
      const pair =
        previous[column - 1] +
        lineSimilarity(
          leftCounts[row - 1],
          rightCounts[column - 1],
          leftTokens[row - 1].length,
          rightTokens[column - 1].length,
        );
      const skipLeft = previous[column] - DISPLAY_ALIGNMENT_GAP;
      const skipRight = current[column - 1] - DISPLAY_ALIGNMENT_GAP;
      // Prefer keeping a pair on ties: IDEA merges lines without equal words
      // into one modified block instead of inventing an insertion.
      if (pair >= skipLeft && pair >= skipRight) {
        current[column] = pair;
        directions[row * width + column] = 0;
      } else if (skipLeft >= skipRight) {
        current[column] = skipLeft;
        directions[row * width + column] = 1;
      } else {
        current[column] = skipRight;
        directions[row * width + column] = 2;
      }
    }
    [previous, current] = [current, previous];
  }
  const pairs: AlignedLine[] = [];
  let row = rows,
    column = columns;
  while (row > 0 || column > 0) {
    const direction = row > 0 && column > 0 ? directions[row * width + column] : row > 0 ? 1 : 2;
    if (direction === 0) {
      const leftIndex = row - 1,
        rightIndex = column - 1;
      const similar = [...leftCounts[leftIndex]].some(([token]) => rightCounts[rightIndex].has(token));
      pairs.push({ left: leftIndex, right: rightIndex, similar });
      row--;
      column--;
    } else if (direction === 1) {
      pairs.push({ left: row - 1, right: null, similar: false });
      row--;
    } else {
      pairs.push({ left: null, right: column - 1, similar: false });
      column--;
    }
  }
  return pairs.reverse();
}

interface DisplayBlock {
  change: IndependentDisplayChange;
  /** Some paired line shares words with its counterpart (IDEA "equal words"). */
  equalWords: boolean;
  /** At least one line of the block contains a word token. */
  hasWords: boolean;
}

function mergeDisplayBlocks(first: DisplayBlock, second: DisplayBlock): DisplayBlock {
  const leftStart = Math.min(first.change.leftStart, second.change.leftStart),
    leftEnd = Math.max(first.change.leftEnd, second.change.leftEnd),
    rightStart = Math.min(first.change.rightStart, second.change.rightStart),
    rightEnd = Math.max(first.change.rightEnd, second.change.rightEnd);
  return {
    change: {
      leftStart,
      leftEnd,
      rightStart,
      rightEnd,
      kind: leftEnd === leftStart ? "inserted" : rightEnd === rightStart ? "deleted" : "modified",
      change: first.change.change,
      first: first.change.first,
    },
    equalWords: first.equalWords || second.equalWords,
    hasWords: first.hasWords || second.hasWords,
  };
}

/** IDEA `LineFragmentSplitter.shouldMergeChunks`: blocks that matched only by
 * newlines, and blocks without words, stay one modified block. */
function shouldMergeDisplayBlocks(first: DisplayBlock, second: DisplayBlock): boolean {
  if (!first.equalWords && !second.equalWords) return true;
  return !first.hasWords || !second.hasWords;
}

/** IDEA's word chunks ignore punctuation-only lines. */
function hasWordToken(text: string): boolean {
  return /[A-Za-z0-9_]|[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}]/u.test(text);
}

function splitDisplayChange(
  change: IndependentChange,
  left: readonly ReviewRow[],
  right: readonly ReviewRow[],
): IndependentDisplayChange[] {
  const leftLines = left.slice(change.leftStart, change.leftEnd).map((row) => row.left ?? "");
  const rightLines = right.slice(change.rightStart, change.rightEnd).map((row) => row.right ?? "");
  if (!leftLines.length || !rightLines.length
    || leftLines.length * rightLines.length > DISPLAY_ALIGNMENT_MAX_CELLS)
    return [{ ...change, change, first: true }];
  const aligned = alignChangeLines(leftLines, rightLines);
  if (!aligned) return [{ ...change, change, first: true }];
  const blocks: DisplayBlock[] = [];
  let current: DisplayBlock | null = null;
  // Context rows separate word chunks; never merge across them.
  let separated = true;
  let leftCursor = change.leftStart,
    rightCursor = change.rightStart;
  const push = (block: DisplayBlock): DisplayBlock => {
    // Merge like IDEA's LineFragmentSplitter before opening another block.
    let pending = block;
    while (!separated && blocks.length) {
      const previous = blocks[blocks.length - 1];
      if (!shouldMergeDisplayBlocks(previous, pending)) break;
      blocks.pop();
      pending = mergeDisplayBlocks(previous, pending);
    }
    blocks.push(pending);
    separated = false;
    return pending;
  };
  for (const { left: leftIndex, right: rightIndex, similar } of aligned) {
    const identical = leftIndex !== null && rightIndex !== null
      && leftLines[leftIndex] === rightLines[rightIndex];
    const kind: CommitDiffKind | null = leftIndex === null ? "inserted"
      : rightIndex === null ? "deleted"
        : identical ? null : "modified";
    if (kind === null) {
      // IDEA's line comparison would have matched these rows as context.
      current = null;
      separated = true;
    } else if (current && current.change.kind === kind) {
      // Extend the open block; both sides advance one line per paired row.
      if (leftIndex !== null) current.change.leftEnd = leftCursor + 1;
      if (rightIndex !== null) current.change.rightEnd = rightCursor + 1;
      current.equalWords ||= similar;
      if (leftIndex !== null) current.hasWords ||= hasWordToken(leftLines[leftIndex]);
      if (rightIndex !== null) current.hasWords ||= hasWordToken(rightLines[rightIndex]);
    } else {
      current = push({
        change: {
          leftStart: leftCursor,
          leftEnd: leftIndex === null ? leftCursor : leftCursor + 1,
          rightStart: rightCursor,
          rightEnd: rightIndex === null ? rightCursor : rightCursor + 1,
          kind,
          change,
          first: blocks.length === 0,
        },
        equalWords: similar,
        hasWords: (leftIndex !== null && hasWordToken(leftLines[leftIndex]))
          || (rightIndex !== null && hasWordToken(rightLines[rightIndex])),
      });
    }
    // A context pair also consumes one row on each side; the cursor is the
    // insertion/deletion boundary for the next painted block.
    if (leftIndex !== null) leftCursor++;
    if (rightIndex !== null) rightCursor++;
  }
  if (!blocks.length) return [{ ...change, change, first: true }];
  blocks[0].change.first = true;
  return blocks.map((block) => block.change);
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
  const displayChanges = changes.flatMap((change) =>
    change.kind === "modified"
      ? splitDisplayChange(change, left, right)
      : [{ ...change, change, first: true }],
  );
  return { rows: projected, left, right, changes, displayChanges };
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
