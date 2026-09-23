import { Registry, INITIAL, parseRawGrammar } from "vscode-textmate";
import { loadWASM, OnigScanner, OnigString } from "vscode-oniguruma";

export { INITIAL };
export async function createJavaGrammar(wasm: ArrayBuffer, grammarText: string) {
  await loadWASM(wasm);
  const registry = new Registry({
    onigLib: Promise.resolve({ createOnigScanner: (sources: string[]) => new OnigScanner(sources), createOnigString: (text: string) => new OnigString(text) }),
    loadGrammar: async (scope) => scope === "source.java" ? parseRawGrammar(grammarText, "java.tmLanguage.json") : null,
  });
  const grammar = await registry.loadGrammar("source.java");
  if (!grammar) throw new Error("Java TextMate grammar failed to load");
  return { registry, grammar };
}

// Per-line wall-time cap. A cap hit is recoverable: follow VS Code's
// TextMateTokenizationSupport and keep the partial tokens while carrying the
// line's starting state forward, because the stack returned mid-line is not a
// valid end-of-line state. A GC pause on an ordinary line must not abort
// tokenization for every open Java document.
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

// Map TextMate's scope stack to the same token theme used by Monaco's lexical
// and semantic layers, rather than installing a competing global color map.
export function tokenRole(scopes: string[]): string {
  for (let i = scopes.length - 1; i >= 0; i--) {
    const scope = scopes[i];
    if (/^comment/.test(scope)) return "comment";
    if (/^string/.test(scope)) return "string";
    if (/^constant.numeric/.test(scope)) return "number";
    if (/^constant.language/.test(scope)) return "keyword";
    if (/^(keyword|storage)/.test(scope)) return "keyword";
    if (/^entity.name.(type|class|namespace)|^support.(class|type)/.test(scope)) return "type.identifier";
    if (/^entity.name.function/.test(scope)) return "function";
    if (/^variable/.test(scope)) return "variable";
    if (/^punctuation/.test(scope)) return "delimiter";
  }
  return "";
}
