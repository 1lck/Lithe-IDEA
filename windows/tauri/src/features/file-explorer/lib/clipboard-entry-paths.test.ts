import { describe, expect, test } from "bun:test";
import {
  clipboardEntryPaths,
  shouldPasteFileClipboardPaths,
} from "./clipboard-entry-paths";

describe("clipboardEntryPaths", () => {
  test("relativizes against the directory the shell is in", () => {
    expect(
      clipboardEntryPaths([{ path: "C:\\work\\proj\\src\\Main.java" }], "C:\\work\\proj"),
    ).toEqual(["src/Main.java"]);
  });

  // Regression: a terminal opened on a subdirectory used to relativize against
  // the workspace root, producing `src/Main.java` where the shell resolved
  // `C:\work\proj\src\src\Main.java`.
  test("relativizes against a subdirectory shell", () => {
    expect(
      clipboardEntryPaths([{ path: "C:\\work\\proj\\src\\Main.java" }], "C:\\work\\proj\\src"),
    ).toEqual(["Main.java"]);
  });

  // When the target directory is unknown, a relative path could resolve to the
  // wrong file, so the full path is the only safe answer.
  test("keeps the full path when the shell directory is unknown", () => {
    expect(clipboardEntryPaths([{ path: "C:\\work\\proj\\a.ts" }], null)).toEqual([
      "C:\\work\\proj\\a.ts",
    ]);
  });

  test("keeps the full path for entries outside the shell directory", () => {
    expect(
      clipboardEntryPaths([{ path: "D:\\other\\Notes.txt" }], "C:\\work\\proj"),
    ).toEqual(["D:\\other\\Notes.txt"]);
  });

  test("keeps every entry separately so the terminal can quote each one", () => {
    expect(
      clipboardEntryPaths(
        [{ path: "C:\\work\\proj\\my folder\\a.ts" }, { path: "C:\\work\\proj\\pkg" }],
        "C:\\work\\proj",
      ),
    ).toEqual(["my folder/a.ts", "pkg"]);
  });

  test("omits the shell directory itself because it has no relative path", () => {
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
