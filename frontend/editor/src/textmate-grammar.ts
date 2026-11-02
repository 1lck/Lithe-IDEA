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

// Map TextMate's scope stack to the same token theme used by Monaco's lexical
// and semantic layers, rather than installing a competing global color map.
export function tokenRole(scopes: string[]): string {
  // The innermost punctuation scope must not discard the enclosing Javadoc role.
  if (scopes.some(scope => /^comment\.block\.(documentation|javadoc)(\.|$)/.test(scope))) return "comment.documentation.java";
  if (scopes.some(scope => /^comment\.block(\.|$)/.test(scope))) return "comment.block.java";
  for (let i = scopes.length - 1; i >= 0; i--) {
    const scope = scopes[i];
    if (/^comment|^punctuation\.definition\.comment/.test(scope)) return "comment.line.java";
    if (/^constant.character.escape/.test(scope)) return "string.escape.java";
    if (/^storage.type.annotation/.test(scope)) return "annotation";
    if (/^string/.test(scope)) return "string.java";
    if (/^constant.numeric/.test(scope)) return "number.java";
    if (/^constant.language/.test(scope)) return "keyword.java";
    if (/^(keyword|storage)/.test(scope)) return "keyword.java";
    if (/^entity.name.(type|class|namespace)|^support.(class|type)/.test(scope)) return "type.identifier";
    if (/^entity.name.function/.test(scope)) return "function.java";
    if (/^variable/.test(scope)) return "variable";
    if (/^punctuation/.test(scope)) return "delimiter";
  }
  return "";
}
