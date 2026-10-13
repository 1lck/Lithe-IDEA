import { afterEach, expect, spyOn, test } from "bun:test";
import { LINE_TIME_LIMIT_MS, tokenizeLineWithinLimit } from "./textmate-line-limit";

type State = { name: string };
const start: State = { name: "line start" };
const midLine: State = { name: "mid-line stack" };
const tokens = [{ startIndex: 0, endIndex: 3, scopes: ["source.java"] }];
function grammar(stoppedEarly: boolean) {
  const calls: number[] = [];
  return {
    calls,
    tokenizeLine(_line: string, _state: State, timeLimit?: number) {
      calls.push(timeLimit ?? 0);
      return { tokens, ruleStack: midLine, stoppedEarly };
    },
  };
}
const warn = spyOn(console, "warn").mockImplementation(() => {});
afterEach(() => warn.mockClear());

test("a completed line passes its end state through with the line time limit", () => {
  const completed = grammar(false);
  const result = tokenizeLineWithinLimit(completed, "int x;", start);
  expect(completed.calls).toEqual([LINE_TIME_LIMIT_MS]);
  expect(result.ruleStack).toBe(midLine);
  expect(result.stoppedEarly).toBe(false);
  expect(warn).not.toHaveBeenCalled();
});

test("a line that hits the time limit keeps its tokens and restarts the next line from its start state", () => {
  const result = tokenizeLineWithinLimit(grammar(true), "    int field5029; // 中文 😀", start);
  expect(result.tokens).toBe(tokens);
  expect(result.ruleStack).toBe(start);
  expect(result.stoppedEarly).toBe(true);
  expect(warn).toHaveBeenCalledTimes(1);
});
