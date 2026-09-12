import { describe, expect, test } from "bun:test";
import {
  cursorEntryToRecordAfterMouseGesture,
  type CursorHistoryEntry,
} from "./mouse-cursor-history";

function entry(line: number, column: number): CursorHistoryEntry {
  return {
    bufferId: "buffer-a",
    filePath: "C:/workspace/a.ts",
    line,
    column,
    offset: line * 100 + column,
    scrollTop: line * 10,
    scrollLeft: column,
  };
}

describe("mouse cursor history", () => {
  test("records the gesture start when the cursor moved", () => {
    const start = entry(10, 20);

    expect(cursorEntryToRecordAfterMouseGesture(start, entry(20, 5))).toEqual(start);
  });

  test("does not record a click without cursor movement", () => {
    const start = entry(10, 20);

    expect(cursorEntryToRecordAfterMouseGesture(start, entry(10, 20))).toBeNull();
  });

  test("does not record an incomplete gesture", () => {
    expect(cursorEntryToRecordAfterMouseGesture(null, entry(20, 5))).toBeNull();
    expect(cursorEntryToRecordAfterMouseGesture(entry(10, 20), null)).toBeNull();
  });
});
