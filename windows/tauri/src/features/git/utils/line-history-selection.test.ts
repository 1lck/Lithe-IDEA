import { describe, expect, test } from "bun:test";
import { gutterLineRange } from "./line-history-selection";

describe("gutterLineRange", () => {
  test("clicks outside the selection query only the clicked line", () => {
    expect(gutterLineRange(50, { firstLine: 10, lastLine: 20, lastLineColumn: 4 })).toEqual({
      startLine: 50,
      endLine: 50,
    });
  });

  test("clicks inside the selection query the whole selection", () => {
    expect(gutterLineRange(15, { firstLine: 10, lastLine: 20, lastLineColumn: 4 })).toEqual({
      startLine: 10,
      endLine: 20,
    });
  });

  test("an end caret on the next line's first column drops that line", () => {
    expect(gutterLineRange(20, { firstLine: 10, lastLine: 21, lastLineColumn: 1 })).toEqual({
      startLine: 10,
      endLine: 20,
    });
    expect(gutterLineRange(21, { firstLine: 10, lastLine: 21, lastLineColumn: 1 })).toEqual({
      startLine: 21,
      endLine: 21,
    });
  });

  test("a single-line selection with a first-column caret still queries itself", () => {
    expect(gutterLineRange(7, { firstLine: 7, lastLine: 7, lastLineColumn: 1 })).toEqual({
      startLine: 7,
      endLine: 7,
    });
  });

  test("without a selection the clicked line is queried alone", () => {
    expect(gutterLineRange(3, null)).toEqual({ startLine: 3, endLine: 3 });
  });
});
