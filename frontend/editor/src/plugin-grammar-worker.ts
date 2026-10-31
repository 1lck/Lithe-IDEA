import { compile } from "monaco-editor/esm/vs/editor/standalone/common/monarch/monarchCompile.js";
import { MonarchTokenizer } from "monaco-editor/esm/vs/editor/standalone/common/monarch/monarchLexer.js";

/** Reuse pinned Monaco's engine, but never compile/run plugin regexes on the UI thread. */
export function installPluginGrammarWorker() {
  let tokenizer: any;
  const documents = new Map<number, { lines: string[]; version: number; cursor: number; state: any }>();
  const queue = new MessageChannel();
  queue.port1.onmessage = ({ data: id }) => {
    const document = documents.get(id);
    if (!document) return;
    try {
      const rows = [], started = performance.now();
      while (document.cursor < document.lines.length && rows.length < 64) {
        const line = document.lines[document.cursor];
        const result = tokenizer.tokenize(line, true, document.state);
        document.state = result.endState;
        rows.push({ line: ++document.cursor, tokens: result.tokens });
        if (performance.now() - started > 8) break;
      }
      const complete = document.cursor === document.lines.length;
      postMessage({ type: "tokens", id, version: document.version, rows, complete });
      if (!complete) queue.port2.postMessage(id);
    } catch (error) { postMessage({ type: "error", message: String(error) }); }
  };
  self.onmessage = ({ data }) => {
    try {
      if (data.type === "init") {
        // Only the worker parses the source: cases retain package order even
        // after the host's Rust/Swift dictionary and JSON roundtrips.
        const grammar = JSON.parse(data.source);
        grammar.start ??= "root";
        // Monarch's public engine needs configuration/language services even
        // for lexical-only use. Embedded languages remain plain text here.
        tokenizer = new MonarchTokenizer({
          isRegisteredLanguageId: () => false,
          getLanguageIdByLanguageName: () => null, getLanguageIdByMimeType: () => null,
          languageIdCodec: { encodeLanguageId: () => 1 }, requestBasicLanguageFeatures() {},
        }, {}, data.languageID, compile(data.languageID, grammar), {
          getValue: () => 20_000,
          onDidChangeConfiguration: () => ({ dispose() {} }),
        });
        postMessage({ type: "ready" }); return;
      }
      if (data.type === "dispose") { documents.delete(data.id); return; }
      if (data.type === "open") {
        const previous = documents.get(data.id);
        if (previous && previous.version > data.version) return;
        documents.set(data.id, { lines: data.lines, version: data.version, cursor: 0, state: tokenizer.getInitialState() });
        queue.port2.postMessage(data.id);
      }
    } catch (error) { postMessage({ type: "error", message: String(error) }); }
  };
}
