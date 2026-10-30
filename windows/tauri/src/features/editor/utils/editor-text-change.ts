import type { EditorTextChange } from "../types/editor.types";

export function applyEditorTextChangesToContent(
  content: string,
  changes: readonly EditorTextChange[],
): string {
  if (changes.length === 0) return content;

  const ordered = [...changes].sort((left, right) => right.rangeOffset - left.rangeOffset);
  let next = content;
  for (const change of ordered) {
    const start = Math.max(0, Math.min(change.rangeOffset, next.length));
    const end = Math.max(start, Math.min(start + Math.max(0, change.rangeLength), next.length));
    next = `${next.slice(0, start)}${change.text}${next.slice(end)}`;
  }
  return next;
}

export function sortEditorTextChangesForOriginalDocument(
  changes: readonly EditorTextChange[],
): EditorTextChange[] {
  return [...changes].sort((left, right) => right.rangeOffset - left.rangeOffset);
}

/** Beyond this, sending the whole document is cheaper than proving a replay. */
const MAX_REPLAYED_CHANGES = 32;

/**
 * Applies `changes` the way LSP does: in order, each relative to the previous
 * result. Returns undefined when they cannot be replayed.
 */
export function replayEditorTextChanges(
  content: string,
  changes: readonly EditorTextChange[],
): string | undefined {
  if (changes.length > MAX_REPLAYED_CHANGES) return undefined;
  let next = content;
  for (const { rangeOffset, rangeLength, startLine, text } of changes) {
    if (startLine === undefined || rangeOffset + rangeLength > next.length) return undefined;
    next = `${next.slice(0, rangeOffset)}${text}${next.slice(rangeOffset + rangeLength)}`;
  }
  return next;
}
