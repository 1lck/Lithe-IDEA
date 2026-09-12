import type { JumpListEntry } from "../stores/jump-list.store";

export type CursorHistoryEntry = Omit<JumpListEntry, "timestamp">;

function cursorEntriesEqual(left: CursorHistoryEntry, right: CursorHistoryEntry): boolean {
  return (
    left.bufferId === right.bufferId &&
    left.filePath === right.filePath &&
    left.line === right.line &&
    left.column === right.column &&
    left.offset === right.offset
  );
}

/**
 * Returns the position before a mouse gesture when the gesture moved the cursor.
 * A click without movement does not create a jump-list entry.
 */
export function cursorEntryToRecordAfterMouseGesture(
  gestureStart: CursorHistoryEntry | null,
  gestureEnd: CursorHistoryEntry | null,
): CursorHistoryEntry | null {
  if (!gestureStart || !gestureEnd || cursorEntriesEqual(gestureStart, gestureEnd)) {
    return null;
  }

  return gestureStart;
}
