import * as monaco from "monaco-editor/esm/vs/editor/editor.api.js";
import "monaco-editor/esm/vs/editor/editor.all.js";
import "monaco-editor/esm/vs/basic-languages/java/java.contribution.js";
import { isCancellationError } from "monaco-editor/esm/vs/base/common/errors.js";
// Deliberately reuse one pure Windows helper; this is not a portable workbench package.
import { toMonacoModelValue } from "@lithe/editor/line-endings";

declare global {
  interface Window { webkit: any; MonacoEnvironment: any; probe: any; }
}
const status = document.querySelector("#status")!;
const assert = (value: unknown, message: string) => { if (!value) throw new Error(message); };
const deadline = async <T>(promise: Promise<T>, label: string): Promise<T> => {
  let timer: ReturnType<typeof setTimeout>;
  try {
    return await Promise.race([promise, new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error(`${label}: 15s deadline exceeded`)), 15_000);
    })]);
  } finally { clearTimeout(timer!); }
};
const send = (body: object) => deadline(window.webkit.messageHandlers.probe.postMessage(body), "native bridge");
let rendering = true;
const frame = () => rendering
  ? deadline(new Promise<number>(resolve => requestAnimationFrame(resolve)), "animation frame")
  : Promise.resolve(performance.now());
const workers: Worker[] = [];
let workerURL: string;
let editor: monaco.editor.IStandaloneCodeEditor;
let model: monaco.editor.ITextModel;
let revision = 0;
let bridge: Promise<unknown> = Promise.resolve();
let suppress = false;
let fatal: unknown;
const fail = (error: unknown) => {
  fatal = error;
  status.textContent = String(error);
  void send({ type: "failure", message: String(error) }).catch(console.error);
};
addEventListener("error", event => fail(event.message));
addEventListener("unhandledrejection", event => {
  // Disposing a worker or detaching a model cancels outstanding Monaco work.
  // Keep actual bridge failures fatal; only the library's cancellation type is benign.
  if (isCancellationError(event.reason)) { event.preventDefault(); return; }
  fail(event.reason);
});
const save = async () => {
  await bridge;
  if (fatal) throw fatal;
  const result: any = await send({ type: "save", revision, expected: model.getValue() });
  status.textContent = `已保存实验副本 · revision ${result.revision}`;
};

async function open(text: string, id: string) {
  await bridge;
  suppress = true;
  editor.setModel(null);
  model?.dispose();
  revision = 0;
  const normalized = toMonacoModelValue(text);
  await send({ type: "open", text: normalized, id });
  model = monaco.editor.createModel(normalized, "java", monaco.Uri.parse(`inmemory://probe/${id}.java`));
  editor.setModel(model);
  suppress = false;
  await frame();
}

async function run() {
  const cases: { name: string; durationMs: number; metrics?: object }[] = [];
  async function check(name: string, work: () => Promise<object | void>) {
    await send({ type: "progress", name });
    const started = performance.now();
    const metrics = await deadline(work(), name);
    cases.push({ name, durationMs: performance.now() - started, ...(metrics ? { metrics } : {}) });
    status.textContent = `通过：${name}`;
  }
  await check("UTF-16 edits, undo, redo, save barrier", async () => {
    await open("class Probe {\r\n  // 中文 日本語 😀\r\n}\r\n", "unicode");
    const before = model.getValue();
    editor.executeEdits("probe", [{ range: new monaco.Range(2, 6, 2, 8), text: "输入🙂" }]);
    editor.pushUndoStop();
    const after = model.getValue();
    assert(after !== before && after.includes("输入🙂"), "edit did not reach model");
    await model.undo();
    assert(model.getValue() === before, "undo mismatch");
    await model.redo();
    assert(model.getValue() === after, "redo mismatch");
    await save();
  });
  await check("stale revision is rejected without modifying native text", async () => {
    await bridge;
    let rejected = false;
    try { await send({ type: "edit", baseRevision: revision - 1, changes: [] }); }
    catch { rejected = true; }
    assert(rejected, "native host accepted a stale edit");
    await save();
  });
  await check("invalid UTF-16 range batch is rejected atomically", async () => {
    await bridge;
    let rejected = false;
    try { await send({ type: "edit", baseRevision: revision, changes: [
      { offset: 1, length: 0, text: "should never be published" },
      { offset: -1, length: 0, text: "invalid" },
    ] }); } catch { rejected = true; }
    assert(rejected, "native host accepted an invalid range");
    await save();
  });
  await check("Monaco worker RPC mirrors the actual document", async () => {
    const worker = monaco.editor.createWebWorker<any>({ worker: window.MonacoEnvironment.getWorker() });
    try {
      const proxy = await deadline(worker.withSyncedResources([model.uri]), "worker sync");
      const mirrors = await deadline(proxy.inspect(), "worker RPC") as any[];
      assert(mirrors.some(item => item.uri === model.uri.toString() && item.length === model.getValueLength()), "worker mirror mismatch");
      assert(workers.length > 0, "no Web Worker created");
    } finally { worker.dispose(); }
  });
  for (const lines of rendering ? [1_000, 10_000, 50_000] : []) {
    await check(`Java ${lines} lines: open, decorations, scrolling, retained model`, async () => {
      const source = Array.from({ length: lines }, (_, i) => `  public int method${i}() { return ${i}; } // 中文 😀${i % 16 === 0 ? " long comment".repeat(24) : ""}`).join("\n");
      const started = performance.now();
      await open(source, `java-${lines}`);
      const openMs = performance.now() - started;
      const tokens = monaco.editor.tokenize("public class Probe {}", "java");
      assert(tokens[0].some(token => token.type.includes("keyword")), "Java tokenizer not active");
      const decorations = editor.createDecorationsCollection(Array.from({ length: Math.min(lines, 2_000) }, (_, i) => ({
        range: new monaco.Range(i + 1, 3, i + 1, 9), options: { inlineClassName: "probe-decoration" },
      })));
      monaco.editor.setModelMarkers(model, "probe", Array.from({ length: Math.min(lines, 2_000) }, (_, i) => ({
        startLineNumber: i + 1, endLineNumber: i + 1, startColumn: 3, endColumn: 9,
        message: "Synthetic diagnostic load", severity: monaco.MarkerSeverity.Warning,
      })));
      const metrics: Record<string, unknown> = { openMs };
      for (const wrap of ["off", "on"] as const) {
        editor.updateOptions({ wordWrap: wrap });
        const intervals: number[] = [];
        let last = await frame();
        for (let i = 0; i < 100; i++) {
          editor.revealLineInCenter(1 + Math.floor((lines - 1) * (i % 20) / 19), monaco.editor.ScrollType.Immediate);
          const now = await frame(); intervals.push(now - last); last = now;
        }
        intervals.sort((a, b) => a - b);
        metrics[wrap] = { p50: intervals[49], p95: intervals[94], max: intervals[99], samples: intervals.length };
      }
      const original = model;
      const state = editor.saveViewState();
      const other = monaco.editor.createModel("// another tab", "java");
      editor.setModel(other); editor.setModel(original); editor.restoreViewState(state!); other.dispose();
      assert(editor.getModel() === original, "tab switch recreated model");
      decorations.clear();
      monaco.editor.setModelMarkers(model, "probe", []);
      editor.updateOptions({ wordWrap: "off" });
      await save();
      return metrics;
    });
  }
  await check("retained tab undo history", async () => {
    // Keep the current model so this scenario isolates undo ownership across tabs.
    await bridge;
    const before = model.getValue();
    editor.executeEdits("probe", [{ range: new monaco.Range(1, 1, 1, 1), text: "// changed\n" }]);
    editor.pushUndoStop();
    const retained = model;
    const other = monaco.editor.createModel("// other tab", "java");
    editor.setModel(other); editor.setModel(retained); other.dispose();
    await model.undo();
    assert(model.getValue() === before, "tab switch lost undo history");
    await save();
  });
  if (rendering) {
    await check("20k-character line rendering", async () => {
      await open(`class LongLine { String value = "${"x".repeat(20_000)}"; }`, "long-line");
      await save();
    });
    await open("public class Hello {\n    // 中文 / 日本語 / 😀 — manual IME remains to be verified\n    public static void main(String[] args) {\n        System.out.println(\"Hello, Monaco on WKWebView!\");\n    }\n}\n", "preview");
    await frame();
  }
  await send({ type: "complete", cases, userAgent: navigator.userAgent, workers: workers.length });
  status.textContent = "自动验证完成；可继续手动测试输入法、触控板与快捷键";
}

async function main() {
  const workerResponse = await fetch("worker.js");
  assert(workerResponse.ok, "worker asset unavailable");
  workerURL = URL.createObjectURL(new Blob([await workerResponse.text()], { type: "text/javascript" }));
  window.MonacoEnvironment = { getWorker() {
    const worker = new Worker(workerURL); workers.push(worker); return worker;
  } };
  editor = monaco.editor.create(document.querySelector("#editor") as HTMLElement, {
    model: null, theme: "vs-dark", fontFamily: "Menlo, monospace", fontSize: 13,
    automaticLayout: true, minimap: { enabled: false }, scrollBeyondLastLine: false,
  });
  editor.onDidChangeModelContent(event => {
    if (suppress) return;
    const baseRevision = revision++;
    const changes = event.changes.map(change => ({ offset: change.rangeOffset, length: change.rangeLength, text: change.text }));
    bridge = bridge.then(() => send({ type: "edit", baseRevision, changes })).catch(error => { fail(error); throw error; });
  });
  editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS, () => void save().catch(fail));
  document.querySelector("#save")!.addEventListener("click", () => void save().catch(fail));
  let wrap = false;
  document.querySelector("#wrap")!.addEventListener("click", () => editor.updateOptions({ wordWrap: (wrap = !wrap) ? "on" : "off" }));
  window.probe = { run, save };
  addEventListener("pagehide", () => { editor.dispose(); model?.dispose(); workers.forEach(worker => worker.terminate()); URL.revokeObjectURL(workerURL); });
  const startup: any = await send({ type: "ready" });
  rendering = !startup.logicOnly;
  if (startup.automated) await run();
  else { await open(startup.text, "manual"); editor.focus(); status.textContent = "手动验证 · 仅保存实验副本"; }
}
void main().catch(fail);
