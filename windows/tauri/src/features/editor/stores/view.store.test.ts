import { describe, expect, test } from "bun:test";
import { applyEditorTextChangeToLines } from "../stores/view.store";

describe("applyEditorTextChangeToLines", () => {
  test("inserts into one line without copying the untouched prefix and suffix via spreads of new arrays beyond splice", () => {
    const lines = ["alpha", "bravo", "charlie"];
    const result = applyEditorTextChangeToLines(lines, {
      rangeOffset: 6,
      rangeLength: 0,
      text: "X",
      startLine: 1,
      startColumn: 0,
      endLine: 1,
      endColumn: 0,
    });
    expect(result).toEqual(["alpha", "Xbravo", "charlie"]);
    expect(result).toBe(lines);
  });

  test("splits a line when a newline is inserted", () => {
    const lines = ["hello world"];
    expect(
      applyEditorTextChangeToLines(lines, {
        rangeOffset: 5,
        rangeLength: 0,
        text: "\n",
        startLine: 0,
        startColumn: 5,
        endLine: 0,
        endColumn: 5,
      }),
    ).toEqual(["hello", " world"]);
  });
});
