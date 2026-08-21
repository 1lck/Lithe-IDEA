import { describe, expect, test } from "bun:test";
import { applyEditorTextChangesToContent } from "./editor-text-change";

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
