import { type JumpListEntry, useJumpListStore } from "../stores/jump-list.store";

export type CursorHistoryEntry = JumpListEntry;

/**
 * Records a completed mouse gesture as a jump from its start position. Core
 * ignores a gesture that ends where it started, so a click without movement
 * adds no history. One call per gesture keeps this off the per-cursor-move path.
 */
export function recordMouseGesture(
  gestureStart: CursorHistoryEntry | null,
  gestureEnd: CursorHistoryEntry | null,
): void {
  if (!gestureStart || !gestureEnd) return;
  void useJumpListStore.getState().actions.record(gestureStart, gestureEnd);
}
