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
  test("uses the copied file paths while the clipboard still holds the same text", () => {
    expect(
      shouldPasteFileClipboardPaths({
        entryCount: 1,
        sourceClipboardText: "unchanged",
        currentClipboardText: "unchanged",
      }),
    ).toBe(true);
  });

  // Copying text after copying files must win, otherwise the terminal would
  // silently insert stale paths instead of what the user copied last.
  test("defers to text copied after the file copy", () => {
    expect(
      shouldPasteFileClipboardPaths({
        entryCount: 1,
        sourceClipboardText: "before",
        currentClipboardText: "copied later",
      }),
    ).toBe(false);
  });

  test("defers when there is no remembered snapshot", () => {
    expect(
      shouldPasteFileClipboardPaths({
        entryCount: 1,
        sourceClipboardText: null,
        currentClipboardText: "anything",
      }),
    ).toBe(false);
  });

  test("defers when nothing was copied", () => {
    expect(
      shouldPasteFileClipboardPaths({
        entryCount: 0,
        sourceClipboardText: "unchanged",
        currentClipboardText: "unchanged",
      }),
    ).toBe(false);
  });

  // Documents a deliberate trade-off, not an oversight: recovering the same text
  // twice around a file copy looks exactly like an untouched clipboard without an
  // OS change counter. Inserting the paths keeps copy-and-paste-to-terminal a
  // single step, and the mis-insertion is visible and reversible. If this ever
  // needs to change, the decision in the function comment changes with it.
  test("keeps file paths when the same text was copied again around the file copy", () => {
    expect(
      shouldPasteFileClipboardPaths({
        entryCount: 1,
        sourceClipboardText: "echo hello",
        currentClipboardText: "echo hello",
      }),
    ).toBe(true);
  });
});
