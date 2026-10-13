// Per-line wall-time cap. A cap hit is recoverable: follow VS Code's
// TextMateTokenizationSupport and keep the partial tokens while carrying the
// line's starting state forward, because the stack returned mid-line is not a
// valid end-of-line state. A GC pause on an ordinary line must not abort
// tokenization for every open Java document. This module stays free of
// package imports so the dependency-free shared editor unit lane can test it.
export const LINE_TIME_LIMIT_MS = 20;
type LineGrammar<State, Result> = {
  tokenizeLine(line: string, state: State, timeLimit?: number): Result & { ruleStack: State; stoppedEarly: boolean };
};
export function tokenizeLineWithinLimit<State, Result>(grammar: LineGrammar<State, Result>, line: string, state: State) {
  const result = grammar.tokenizeLine(line, state, LINE_TIME_LIMIT_MS);
  if (!result.stoppedEarly) return result;
  console.warn(`Java tokenization reached the ${LINE_TIME_LIMIT_MS} ms line limit: ${line.slice(0, 100)}`);
  return { ...result, ruleStack: state };
}
