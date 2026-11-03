import { expect, test } from "bun:test";
import { TextmateDocument, type TextmateEdit, type TextmateLineTokenizer } from "./textmate-document";

/** A rule state as small as the real one: inside or outside a block comment. */
class FakeState {
  constructor(readonly commented: boolean) {}
  equals(other: FakeState): boolean { return other.commented === this.commented; }
}
const OUTSIDE = new FakeState(false);
const INSIDE = new FakeState(true);
const asState = (state: FakeState) => state as never;

const tokenizeLine: TextmateLineTokenizer = (line, state) => {
  let commented = (state as unknown as FakeState).commented;
  if (line.includes("/*")) commented = true;
  if (line.includes("*/")) commented = false;
  return { tokens: [line], ruleStack: asState(commented ? INSIDE : OUTSIDE) };
};
const NEVER = () => false;

function open(lines: string[], version = 1) {
  const document = new TextmateDocument(lines, version, asState(OUTSIDE));
  document.tokenize(tokenizeLine, lines.length, NEVER);
  expect(document.complete).toBe(true);
  return document;
}
function insert(line: number, column: number, text: string, rangeOffset = 0): TextmateEdit {
  return { rangeOffset, text, range: { startLineNumber: line, startColumn: column, endLineNumber: line, endColumn: column } };
}
const tokenizedLines = (document: TextmateDocument) =>
  document.tokenize(tokenizeLine, 1_000, NEVER).map(row => row.line);
const fileOf = (lineCount: number) => Array.from({ length: lineCount }, (_, index) => `line ${index}`);

test("an edit that keeps the line's end state tokenizes only that line", () => {
  const document = open(fileOf(10_000));
  expect(document.applyEdit([insert(5_000, 1, "x")], 2)).toBe(true);
  expect(tokenizedLines(document)).toEqual([5_000]);
  expect(document.complete).toBe(true);
});

test("an edit that changes the state runs until the state converges again", () => {
  const document = open(["a", "b", "c */", "d", "e"]);
  document.applyEdit([insert(2, 1, "/* ")], 2);
  // Line 3 ends outside the comment again, exactly as it did before.
  expect(tokenizedLines(document)).toEqual([2, 3]);
});

test("an unterminated comment recolors to the end of the file", () => {
  const document = open(["a", "b", "c", "d"]);
  document.applyEdit([insert(2, 1, "/* ")], 2);
  expect(tokenizedLines(document)).toEqual([2, 3, 4]);
});

test("a pasted block retokenizes every new line and aligns the lines after it", () => {
  const document = open(["a", "b", "c", "d"]);
  document.applyEdit([insert(2, 2, "1\n2\n3")], 2);
  expect(document.lines).toEqual(["a", "b1", "2", "3", "c", "d"]);
  expect(tokenizedLines(document)).toEqual([2, 3, 4]);
  document.applyEdit([insert(5, 1, "x")], 3);
  expect(tokenizedLines(document)).toEqual([5]);
});

test("deleting lines keeps later states aligned", () => {
  const document = open(["a", "b /*", "c", "d */", "e"]);
  document.applyEdit([{ rangeOffset: 0, text: "", range: { startLineNumber: 2, startColumn: 3, endLineNumber: 4, endColumn: 1 } }], 2);
  expect(document.lines).toEqual(["a", "b d */", "e"]);
  expect(tokenizedLines(document)).toEqual([2]);
});

test("a pass interrupted by an earlier edit still finishes the rest of the file", () => {
  const document = open(fileOf(100));
  document.applyEdit([insert(51, 1, "/* ")], 2);
  document.tokenize(tokenizeLine, 10, NEVER);
  // Lines 61 onward still carry their old state when the next edit lands.
  document.applyEdit([insert(1, 1, "x")], 3);
  const rows = tokenizedLines(document);
  expect(rows[0]).toBe(1);
  expect(rows[1]).toBe(61);
  expect(rows[rows.length - 1]).toBe(100);
  expect(document.complete).toBe(true);
});

test("two interrupted passes both reach the end of the file", () => {
  const document = open(fileOf(100));
  document.applyEdit([insert(81, 1, "/* ")], 2);
  document.tokenize(tokenizeLine, 5, NEVER);
  document.applyEdit([insert(41, 1, "/* ")], 3);
  document.tokenize(tokenizeLine, 5, NEVER);
  document.applyEdit([insert(1, 1, "x")], 4);
  const rows = tokenizedLines(document);
  expect(rows[0]).toBe(1);
  expect(rows).toContain(46);
  expect(rows).toContain(86);
  expect(rows[rows.length - 1]).toBe(100);
  expect(document.complete).toBe(true);
});

test("an edit above a finished pass does not repeat it", () => {
  const document = open(fileOf(1_000));
  document.applyEdit([insert(900, 1, "x")], 2);
  expect(tokenizedLines(document)).toEqual([900]);
  document.applyEdit([insert(10, 1, "x")], 3);
  expect(tokenizedLines(document)).toEqual([10]);
});

test("rows the editor dropped are sent again even though their state already matches", () => {
  const document = open(["a", "b", "c", "d"]);
  document.applyEdit([insert(2, 1, "/* ")], 2);
  document.tokenize(tokenizeLine, 1, NEVER);
  document.tokenize(tokenizeLine, 2, NEVER);
  expect(document.complete).toBe(true);
  // The next keystroke made those rows stale before the editor applied them.
  document.applyEdit([insert(2, 4, "x")], 3);
  document.invalidate(2, 4);
  expect(tokenizedLines(document)).toEqual([2, 3, 4]);
});

test("a requested range is tokenized without walking the rest of the file", () => {
  const document = open(fileOf(1_000));
  document.invalidate(10, 13);
  expect(tokenizedLines(document)).toEqual([11, 12, 13]);
  expect(document.complete).toBe(true);
});

test("a stale event is ignored", () => {
  const document = open(["a"], 5);
  expect(document.applyEdit([insert(1, 1, "x")], 5)).toBe(false);
  expect(document.lines).toEqual(["a"]);
});

test("a typing burst during the first pass still reaches the end of the file", () => {
  const document = new TextmateDocument(fileOf(50), 1, asState(OUTSIDE));
  document.tokenize(tokenizeLine, 10, NEVER);
  document.applyEdit([insert(3, 1, "x")], 2);
  const rows = tokenizedLines(document);
  expect(rows[0]).toBe(3);
  expect(rows[rows.length - 1]).toBe(50);
  expect(document.complete).toBe(true);
});
