import { expect, test } from "bun:test";
import { createGoToLineRetry, goToLineSelection, resolveGoToLineTarget } from "./go-to-line";

test("a line-only jump selects the target content without CRLF; a column jump keeps a caret", () => {
  const target = resolveGoToLineTarget({ content: "one\r\na😀b\n", lineNumber: 2, columnNumber: 3, lineCount: 3 });
  expect(target).toEqual({ line: 1, column: 2, offset: 7, lineStartOffset: 5, lineLength: 4 });
  expect(goToLineSelection(target, false)).toBeUndefined();
  expect(goToLineSelection(target, true)).toEqual({
    start: { line: 1, column: 0, offset: 5 },
    end: { line: 1, column: 4, offset: 9 },
  });
});

test("an out-of-range line selects the final empty line", () => {
  const target = resolveGoToLineTarget({ content: "one\n", lineNumber: 100, lineCount: 2 });
  expect(goToLineSelection(target, true)).toEqual({
    start: { line: 1, column: 0, offset: 4 }, end: { line: 1, column: 0, offset: 4 },
  });
});

test("a newer jump or editor unmount cancels stale retries", () => {
  let nextId = 0;
  const callbacks = new Map<number, () => void>();
  const calls: number[] = [];
  let ready = false;
  const retry = createGoToLineRetry(
    (target: number) => { calls.push(target); return ready; },
    (callback) => { const id = ++nextId; callbacks.set(id, callback); return id as unknown as ReturnType<typeof setTimeout>; },
    (id) => { callbacks.delete(id as unknown as number); },
  );
  retry.start(1);
  const stale = callbacks.get(1)!;
  retry.start(2);
  stale();
  ready = true;
  callbacks.get(2)!();
  expect(calls).toEqual([1, 2, 2]);
  ready = false;
  retry.start(3);
  const afterUnmount = callbacks.get(3)!;
  retry.dispose();
  afterUnmount();
  expect(calls).toEqual([1, 2, 2, 3]);
  expect(callbacks.has(3)).toBe(false);
});

test("an unavailable editor stops retrying after ten attempts", () => {
  let callback: (() => void) | undefined;
  let attempts = 0;
  const retry = createGoToLineRetry(
    () => { attempts++; return false; },
    (next) => { callback = next; return 1 as unknown as ReturnType<typeof setTimeout>; },
    () => { callback = undefined; },
  );
  retry.start("target");
  for (let index = 0; index < 9; index++) {
    const next = callback;
    callback = undefined;
    expect(next).toBeDefined();
    next?.();
  }
  expect(attempts).toBe(10);
  expect(callback).toBeUndefined();
  retry.dispose();
});
