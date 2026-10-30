import { createJavaGrammar, INITIAL } from "./textmate-grammar";
import { tokenizeLineWithinLimit } from "./textmate-line-limit";
import { TextmateDocument } from "./textmate-document";
import { diffStateStacksRefEq } from "vscode-textmate";

type Document = { text: TextmateDocument; visible: boolean; timer?: ReturnType<typeof setTimeout> };
const documents = new Map<number, Document>();
const TYPING_DEBOUNCE_MILLISECONDS = 80;
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
  const { text } = document;
  const started = performance.now();
  const rows = text.tokenize((line, state) => tokenizeLineWithinLimit(grammar, line, state), 128, () => performance.now() - started >= 8)
    .map(row => ({ line: row.line, tokens: row.tokens, state: diffStateStacksRefEq(INITIAL, row.ruleStack) }));
  postMessage({ type: "tokens", id, version: text.version, lineCount: text.lines.length, rows, complete: text.complete });
  if (!text.complete) schedule(id);
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
      documents.set(data.id, { text: new TextmateDocument(data.lines, data.version, INITIAL), visible: data.visible });
      schedule(data.id); return;
    }
    const document = documents.get(data.id);
    if (!document) return;
    if (data.type === "dispose") { clearTimeout(document.timer); documents.delete(data.id); return; }
    if (data.type === "visible") { document.visible = data.visible; schedule(data.id); return; }
    if (data.type === "request") { document.text.invalidate(data.start - 1, data.end - 1); schedule(data.id); return; }
    if (data.type === "stale") {
      // These lines were numbered before the edits that made them stale, and
      // the widening covers any lines those edits added or removed above them.
      const shifted = Math.abs(document.text.lines.length - data.lineCount);
      document.text.invalidate(data.start - 1 - shifted, data.end + shifted);
      schedule(data.id, TYPING_DEBOUNCE_MILLISECONDS);
      return;
    }
    if (data.type === "edit" && document.text.applyEdit(data.changes, data.version)) {
      // Coalesce continuous typing; foreground viewport tokenization remains
      // available while the worker waits for a short quiet period.
      schedule(data.id, TYPING_DEBOUNCE_MILLISECONDS);
    }
  } catch (error) { postMessage({ type: "error", message: String(error), id: data.id }); }
};
