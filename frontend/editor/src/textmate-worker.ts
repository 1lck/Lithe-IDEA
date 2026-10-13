import { createJavaGrammar, INITIAL } from "./textmate-grammar";
import { tokenizeLineWithinLimit } from "./textmate-line-limit";
import { diffStateStacksRefEq } from "vscode-textmate";

type Document = { lines: string[]; states: any[]; version: number; cursor: number; visible: boolean; timer?: ReturnType<typeof setTimeout> };
const documents = new Map<number, Document>();
let grammar: any;
const queue = new MessageChannel();
const queued = new Set<number>();
queue.port1.onmessage = ({ data: id }) => {
  queued.delete(id);
  try { tokenize(id); }
  catch (error) { postMessage({ type: "error", message: String(error), id }); }
};
function schedule(id: number, delay = 0) {
  const document = documents.get(id);
  if (!document) return;
  clearTimeout(document.timer);
  if (!document.visible) return;
  const enqueue = () => {
    if (!queued.has(id)) { queued.add(id); queue.port2.postMessage(id); }
  };
  // MessageChannel yields between bounded slices without hidden-tab timer
  // clamping. Only the typing debounce uses wall time.
  if (delay) document.timer = setTimeout(enqueue, delay);
  else enqueue();
}
function tokenize(id: number) {
  const document = documents.get(id);
  if (!document || !document.visible) return;
  const started = performance.now();
  const rows = [];
  while (document.cursor < document.lines.length && rows.length < 128) {
    const index = document.cursor;
    const result = tokenizeLineWithinLimit(grammar, document.lines[index], index === 0 ? INITIAL : document.states[index - 1]);
    document.states[index] = result.ruleStack;
    rows.push({ line: index + 1, tokens: result.tokens, state: diffStateStacksRefEq(INITIAL, result.ruleStack) });
    document.cursor++;
    if (performance.now() - started >= 8) break;
  }
  postMessage({ type: "tokens", id, version: document.version, rows, complete: document.cursor === document.lines.length });
  if (document.cursor < document.lines.length) schedule(id);
}
self.onmessage = async ({ data }) => {
  try {
    if (data.type === "init") {
      grammar = (await createJavaGrammar(data.wasm, data.grammar)).grammar;
      // vscode-textmate/Oniguruma lazily compiles grammar patterns on the first
      // tokenization. Keep that one-time initialization outside the per-line
      // production budget; subsequent document lines still retain the line cap.
      grammar.tokenizeLine("class LitheTokenizerWarmup {}", INITIAL);
      postMessage({ type: "ready" }); return;
    }
    if (data.type === "open") {
      const previous = documents.get(data.id); clearTimeout(previous?.timer);
      documents.set(data.id, { lines: data.lines, version: data.version, states: [], cursor: 0, visible: data.visible });
      schedule(data.id); return;
    }
    const document = documents.get(data.id);
    if (!document) return;
    if (data.type === "dispose") { clearTimeout(document.timer); documents.delete(data.id); return; }
    if (data.type === "visible") { document.visible = data.visible; schedule(data.id); return; }
    if (data.type === "request") { document.cursor = Math.min(document.cursor, data.start - 1); schedule(data.id); return; }
    if (data.type === "edit") {
      if (data.version <= document.version) return;
      for (const change of [...data.changes].sort((a, b) => b.rangeOffset - a.rangeOffset)) {
        const start = change.range.startLineNumber - 1, end = change.range.endLineNumber - 1;
        const replacement = (document.lines[start].slice(0, change.range.startColumn - 1) + change.text + document.lines[end].slice(change.range.endColumn - 1)).split(/\r\n|\n/);
        document.lines.splice(start, end - start + 1, ...replacement);
        document.cursor = Math.min(document.cursor, start);
        document.states.length = Math.min(document.states.length, start);
      }
      document.version = data.version;
      // Coalesce continuous typing; foreground viewport tokenization remains
      // available while the worker waits for a short quiet period.
      schedule(data.id, 80);
    }
  } catch (error) { postMessage({ type: "error", message: String(error), id: data.id }); }
};
