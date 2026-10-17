import { describe, expect, test } from "bun:test";
import {
  clipboardEntryPaths,
  shouldPasteFileClipboardPaths,
} from "./clipboard-entry-paths";

describe("clipboardEntryPaths", () => {
  test("uses workspace-relative paths with forward slashes", () => {
    expect(clipboardEntryPaths([{ path: "C:\\work\\proj\\src\\Main.java" }], "C:\\work\\proj")).toEqual([
      "src/Main.java",
    ]);
  });

  test("keeps the full path for entries outside the workspace", () => {
    expect(clipboardEntryPaths([{ path: "D:\\other\\Notes.txt" }], "C:\\work\\proj")).toEqual([
      "D:\\other\\Notes.txt",
    ]);
  });

  test("keeps the full path when no workspace root is open", () => {
    expect(clipboardEntryPaths([{ path: "C:\\work\\proj\\a.ts" }], undefined)).toEqual([
      "C:\\work\\proj\\a.ts",
    ]);
  });

  test("keeps every entry separately so the terminal can quote each one", () => {
    expect(
      clipboardEntryPaths(
        [{ path: "C:\\work\\proj\\my folder\\a.ts" }, { path: "C:\\work\\proj\\pkg" }],
        "C:\\work\\proj",
      ),
    ).toEqual(["my folder/a.ts", "pkg"]);
  });

  test("omits the workspace root because it has no relative path", () => {
    expect(clipboardEntryPaths([{ path: "C:\\work\\proj" }], "C:\\work\\proj")).toEqual([]);
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
});
