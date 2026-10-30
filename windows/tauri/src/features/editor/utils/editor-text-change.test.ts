import { describe, expect, test } from "bun:test";
import type { EditorTextChange } from "../types/editor.types";
import { applyEditorTextChangesToContent, replayEditorTextChanges } from "./editor-text-change";

describe("applyEditorTextChangesToContent", () => {
  test("inserts a character without scanning the rest of the document", () => {
    expect(
      applyEditorTextChangesToContent("hello", [
        { rangeOffset: 5, rangeLength: 0, text: "!" },
      ]),
    ).toBe("hello!");
  });

  test("applies multiple original-document edits from the end", () => {
    expect(
      applyEditorTextChangesToContent("abcde", [
        { rangeOffset: 1, rangeLength: 1, text: "B" },
        { rangeOffset: 3, rangeLength: 1, text: "D" },
      ]),
    ).toBe("aBcDe");
  });
});

function replace(rangeOffset: number, rangeLength: number, text: string): EditorTextChange {
  return { rangeOffset, rangeLength, text, startLine: 0, startColumn: rangeOffset, endLine: 0, endColumn: rangeOffset + rangeLength };
}

describe("replayEditorTextChanges", () => {
  test("applies each change to the result of the previous one", () => {
    expect(replayEditorTextChanges("abcd", [replace(2, 0, "X"), replace(3, 0, "Y")])).toBe("abXYcd");
  });

  test("replaces the range it covers", () => {
    expect(replayEditorTextChanges("a\r\nb", [replace(1, 2, " ")])).toBe("a b");
  });

  test("refuses ranges outside the document", () => {
    expect(replayEditorTextChanges("ab", [replace(2, 1, "X")])).toBeUndefined();
  });

  test("refuses changes without line coordinates", () => {
    expect(
      replayEditorTextChanges("ab", [{ rangeOffset: 0, rangeLength: 0, text: "X" }]),
    ).toBeUndefined();
  });

  test("leaves very large batches to a full-text sync", () => {
    expect(
      replayEditorTextChanges("", Array.from({ length: 33 }, () => replace(0, 0, "x"))),
    ).toBeUndefined();
  });
});
