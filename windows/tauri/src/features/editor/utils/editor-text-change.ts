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
