import { describe, expect, test } from "bun:test";
import { clipboardEntryPaths, shouldPasteFileClipboardPaths } from "./clipboard-entry-paths";

describe("clipboardEntryPaths", () => {
  // Paths stay absolute: on Windows no shell reports its live directory, so a
  // relative path would resolve against a stale launch directory after `cd`.
  test("keeps the absolute path instead of relativizing it", () => {
    expect(clipboardEntryPaths([{ path: "C:\\work\\proj\\src\\Main.java" }])).toEqual([
      "C:\\work\\proj\\src\\Main.java",
    ]);
  });

  // Regression: a relative path rendered the copied directory itself as an empty
  // string, which used to be filtered out and dropped the insertion entirely.
  test("keeps the path of a directory even when it is the shell directory", () => {
    expect(clipboardEntryPaths([{ path: "C:\\work\\proj\\src" }])).toEqual([
      "C:\\work\\proj\\src",
    ]);
  });

  test("keeps every entry in order", () => {
    expect(
      clipboardEntryPaths([{ path: "C:\\work\\a.ts" }, { path: "C:\\work\\pkg" }]),
    ).toEqual(["C:\\work\\a.ts", "C:\\work\\pkg"]);
  });

  test("drops empty paths", () => {
    expect(clipboardEntryPaths([{ path: "" }, { path: "C:\\work\\a.ts" }])).toEqual([
      "C:\\work\\a.ts",
    ]);
  });

  test("returns nothing when there are no entries", () => {
    expect(clipboardEntryPaths([])).toEqual([]);
  });
});

describe("shouldPasteFileClipboardPaths", () => {
  test("uses the copied file paths while the clipboard counter is unchanged", () => {
    expect(
      shouldPasteFileClipboardPaths({
        entryCount: 1,
        sourceSequence: 42,
        currentSequence: 42,
      }),
    ).toBe(true);
  });

  // The whole reason for a counter instead of the text: copying different content
  // after the file copy must win, so the terminal inserts what the user copied
  // last.
  test("defers to anything copied after the file copy", () => {
    expect(
      shouldPasteFileClipboardPaths({
        entryCount: 1,
        sourceSequence: 42,
        currentSequence: 43,
      }),
    ).toBe(false);
  });

  // Regression: comparing text could not detect this case, because copying the
  // same string twice leaves the content identical while the counter advances.
  test("defers when the same text was copied again after the file copy", () => {
    expect(
      shouldPasteFileClipboardPaths({
        entryCount: 1,
        sourceSequence: 42,
        currentSequence: 45,
      }),
    ).toBe(false);
  });

  // The backend reports 0 when the platform has no change counter, so 0 must be
  // treated as "unknown": two zero readings are not evidence that nothing changed.
  test("treats a zero counter as unknown and defers to the clipboard text", () => {
    expect(
      shouldPasteFileClipboardPaths({
        entryCount: 1,
        sourceSequence: 0,
        currentSequence: 0,
      }),
    ).toBe(false);
    expect(
      shouldPasteFileClipboardPaths({
        entryCount: 1,
        sourceSequence: 0,
        currentSequence: 42,
      }),
    ).toBe(false);
  });

  test("defers when either reading is unavailable", () => {
    expect(
      shouldPasteFileClipboardPaths({
        entryCount: 1,
        sourceSequence: null,
        currentSequence: 42,
      }),
    ).toBe(false);
    expect(
      shouldPasteFileClipboardPaths({
        entryCount: 1,
        sourceSequence: 42,
        currentSequence: null,
      }),
    ).toBe(false);
  });

  test("defers when nothing was copied", () => {
    expect(
      shouldPasteFileClipboardPaths({
        entryCount: 0,
        sourceSequence: 42,
        currentSequence: 42,
      }),
    ).toBe(false);
  });

  // Regression: the counter must describe the copy that produced the entries.
  // When a window receives a copy from another window it has to compare against
  // that copy's counter, not one left over from its own earlier copy — otherwise
  // the entries and the counter describe different operations.
  test("compares against the counter that came with the entries", () => {
    const entryStateFromOtherWindow = { entries: [{ path: "C:\\a.txt" }], source_sequence: 50 };
    const thisWindowLeftover = 42;

    expect(
      shouldPasteFileClipboardPaths({
        entryCount: entryStateFromOtherWindow.entries.length,
        sourceSequence: entryStateFromOtherWindow.source_sequence,
        currentSequence: 50,
      }),
    ).toBe(true);

    // The same paste judged with this window's stale counter would have been
    // wrong, which is what the reported bug did.
    expect(
      shouldPasteFileClipboardPaths({
        entryCount: entryStateFromOtherWindow.entries.length,
        sourceSequence: thisWindowLeftover,
        currentSequence: 50,
      }),
    ).toBe(false);
  });
});
