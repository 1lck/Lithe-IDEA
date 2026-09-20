import { expect, test } from "bun:test";
import { SourceText } from "./source-text";

const normalized = (text: string) => text.replace(/\r\n|\r/g, "\n");
function applyNative(text: string, changes: { offset: number; length: number; text: string }[]) {
  for (const change of [...changes].sort((a, b) => b.offset - a.offset)) {
    text = text.slice(0, change.offset) + change.text + text.slice(change.offset + change.length);
  }
  return text;
}

test("mixed newline edits and grouped undo preserve source bytes", () => {
  const original = "first\r\n中文😀\nthird\rfourth";
  const source = new SourceText(original, 1);
  let native = original;
  const edits = [{ rangeOffset: 6, rangeLength: 4, text: "hello\nworld" },
    { rangeOffset: 17, rangeLength: 6, text: "last" }];
  native = applyNative(native, source.apply(edits, 2));
  expect(source.value).toBe(native);
  expect(native).toBe("first\r\nhello\r\nworld\nthird\rlast");
  native = applyNative(native, source.apply([{ rangeOffset: 0, rangeLength: normalized(native).length, text: normalized(original) }], 1));
  expect(source.value).toBe(original);
  expect(native).toBe(original);
});

test("selection ranges keep their source text after CRLF normalization", () => {
  const original = "first line\r\nselected second line\r\nthird line\r\n";
  const model = normalized(original);
  const start = model.indexOf("selected second line");
  const end = model.indexOf("\nthird line");
  const source = new SourceText(original, 1);

  expect(source.textInNormalizedRange(start, end - start)).toBe("selected second line");
  expect(source.textInNormalizedRange(0, end)).toBe("first line\r\nselected second line");
});

test("persistent pieces survive bounded repeated edits across chunk boundaries", () => {
  const original = "a\r\n".repeat(2000);
  const source = new SourceText(original, 1);
  let native = original;
  let model = normalized(original);
  for (let index = 0; index < 300; index++) {
    const offset = (index * 997) % (model.length + 1);
    const text = index % 2 ? "中😀" : "new\nline";
    native = applyNative(native, source.apply([{ rangeOffset: offset, rangeLength: 0, text }], index + 2));
    model = model.slice(0, offset) + text + model.slice(offset);
    expect(source.value).toBe(native);
    expect(normalized(native)).toBe(model);
  }
  const undo = source.apply([{ rangeOffset: 0, rangeLength: model.length, text: normalized(original) }], 1);
  expect(applyNative(native, undo)).toBe(original);
});


test("joining bare CR with LF preserves two logical lines and undo restores bytes", () => {
  const source = new SourceText("a\rx\nb", 1);
  const changes = source.apply([{ rangeOffset: 2, rangeLength: 1, text: "" }], 2);
  expect(applyNative("a\rx\nb", changes)).toBe("a\n\nb");
  expect(normalized(source.value)).toBe("a\n\nb");
  const undo = source.apply([{ rangeOffset: 2, rangeLength: 0, text: "x" }], 1);
  expect(source.value).toBe("a\rx\nb");
  expect(applyNative("a\n\nb", undo)).toBe("a\rx\nb");
});


test("expanded source patches never split neighboring emoji", () => {
  const original = "😀x🙂";
  const source = new SourceText(original, 1);
  const patches = source.apply([{ rangeOffset: 2, rangeLength: 1, text: "中" }], 2);
  expect(patches).toEqual([{ offset: 0, length: 5, text: "😀中🙂" }]);
  expect(applyNative(original, patches)).toBe(source.value);
});

test("mixed newline piece edits keep normalized offsets valid after deletions", () => {
  const original = "left\rmiddle\nright\r\n".repeat(1000);
  const source = new SourceText(original, 1);
  let native = original;
  let model = normalized(original);
  for (let index = 0; index < 400; index++) {
    const offset = (index * 491) % model.length;
    const count = Math.min((index * 13) % 40, model.length - offset);
    const text = index % 3 ? "" : "new\n";
    const changes = source.apply([{ rangeOffset: offset, rangeLength: count, text }], index + 2);
    native = applyNative(native, changes);
    model = model.slice(0, offset) + text + model.slice(offset + count);
    expect(source.value).toBe(native);
    expect(normalized(native)).toBe(model);
  }
  const undo = source.apply([{ rangeOffset: 0, rangeLength: model.length, text: normalized(original) }], 1);
  expect(applyNative(native, undo)).toBe(original);
});

test("branching after grouped undo preserves both surviving undo and new redo bytes", () => {
  const original = "first\r\n😀middle\rlast\n";
  const source = new SourceText(original, 1);
  let native = original;
  const change = (text: string, version: number) => {
    native = applyNative(native, source.apply([
      { rangeOffset: 0, rangeLength: normalized(native).length, text: normalized(text) },
    ], version));
    expect(native).toBe(source.value);
  };
  change("first\nchanged\nlast\n", 2);
  const surviving = native;
  change("old redo branch\n", 3);
  change("old redo branch\nmore\n", 4);
  // Grouped undo skips version 3; versionId keeps increasing while Monaco
  // restores alternativeVersionId 2, then assigns a fresh ID to the new edit.
  change(surviving, 2);
  change("new branch\n", 6);
  const branched = native;
  change(surviving, 2);
  expect(native).toBe(surviving);
  change(original, 1);
  expect(native).toBe(original);
  change(surviving, 2);
  change(branched, 6);
  expect(native).toBe(branched);
});

test("external replacement after undo retains exact newlines on the surviving branch", () => {
  const original = "a\r\nb\rc\n";
  const source = new SourceText(original, 1);
  source.apply([{ rangeOffset: 0, rangeLength: 6, text: "discarded\n" }], 2);
  source.apply([{ rangeOffset: 0, rangeLength: 10, text: normalized(original) }], 1);
  const external = "external\rnew\r\nlast\n";
  source.replace(external, 4);
  expect(applyNative(external, source.apply([
    { rangeOffset: 0, rangeLength: normalized(external).length, text: normalized(original) },
  ], 1))).toBe(original);
  expect(applyNative(original, source.apply([
    { rangeOffset: 0, rangeLength: normalized(original).length, text: normalized(external) },
  ], 4))).toBe(external);
});

test("long editing history remains undoable without a fixed version count cap", () => {
  const original = "a\r\nb\rc\n";
  const source = new SourceText(original, 1);
  let native = original;
  for (let version = 2; version <= 2002; version++) {
    native = applyNative(native, source.apply([{ rangeOffset: 0, rangeLength: 0, text: "x" }], version));
  }
  expect(applyNative(native, source.apply([
    { rangeOffset: 0, rangeLength: 2001, text: "" },
  ], 1))).toBe(original);
});
