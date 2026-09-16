import { runEditorCommand } from "@lithe/editor/editor-commands";
import { ICommandService } from "monaco-editor/esm/vs/platform/commands/common/commands.js";
import { IBulkEditService } from "monaco-editor/esm/vs/editor/browser/services/bulkEditService.js";
import { CompletionItem } from "monaco-editor/esm/vs/editor/contrib/suggest/browser/suggest.js";
import { SuggestController } from "monaco-editor/esm/vs/editor/contrib/suggest/browser/suggestController.js";
import { Position } from "monaco-editor/esm/vs/editor/common/core/position.js";
import diffFixture from "../../../shared/fixtures/editor/diff-review-v1.json";
import { mountDiffReview, projectReviewRows, type ReviewRow } from "@lithe/editor/diff-review";
import { StandaloneServices } from "monaco-editor/esm/vs/editor/standalone/browser/standaloneServices.js";
import { ILanguageFeaturesService } from "monaco-editor/esm/vs/editor/common/services/languageFeatures.js";
import { CancellationTokenSource, CancellationToken } from "monaco-editor/esm/vs/base/common/cancellation.js";
import { ready } from "./workbench";
import { acquireEditorModelSource, sourcePositionAt } from "@lithe/editor/model-source";
import { editor as monacoEditor, languages, Range, Selection, Uri } from "monaco-editor/esm/vs/editor/editor.api.js";

// Real WebKit integration, using the exact workbench bundle and the existing
// bounded native probe host. No DOM-based imitation of Monaco input.
const send = (body: object) => window.webkit.messageHandlers.litheEditor.postMessage(body);
const assert = (condition: unknown, message: string) => { if (!condition) throw new Error(message); };
const assertRejects = async (operation: () => Promise<unknown>, message: string) => {
  try { await operation(); } catch { return; }
  throw new Error(message);
};

async function verify() {
  await ready;
  const cases: { name: string; durationMs: number }[] = [];
  async function check(name: string, operation: () => Promise<void>) {
    await send({ type: "progress", name });
    const started = performance.now();
    await operation();
    cases.push({ name, durationMs: performance.now() - started });
  }
  await check("diff projections preserve sparse source lines and release read-only models", async () => {
    const before = monacoEditor.getModels().length;
    const container = document.createElement("div");
    container.style.cssText = "position:absolute;inset:0;height:600px";
    document.body.append(container);
    const calls: string[] = [];
    const review = mountDiffReview(container, (hunk, action) => calls.push(`${hunk}:${action}`));
    const rows = diffFixture.rows as ReviewRow[];
    try {
      await review.update({ rows, language: "java", collapse: false, actions: [{ id: "stage", title: "Stage" }] });
      const old = review.editor.getOriginalEditor(), next = review.editor.getModifiedEditor();
      assert(old.getModel()!.getValue() === diffFixture.originalText, "original projection changed patch text");
      assert(next.getModel()!.getLineCount() === 4, "projection invented missing context or null-side lines");
      const lineNumbers = next.getRawOptions().lineNumbers as (line: number) => string;
      assert(lineNumbers(1) === "" && lineNumbers(4) === "501", "patch line numbers became display offsets");
      assert(old.getRawOptions().readOnly && next.getRawOptions().readOnly, "review became editable");
      review.select({ selectedIDs: ["line-3"], searchIDs: ["line-4"], revealID: "line-4" });
      assert(next.getPosition()?.lineNumber === 4, "stable row navigation chose wrong source line");
      review.select({ revealID: "line-3", matches: [{ rowID: "line-3", startColumn: 1, endColumn: 4, current: true }] });
      assert(next.getSelection()?.endColumn === 4, "search lost the exact match range");
      review.select({ revealID: "line-3", matches: [{ rowID: "line-3", startColumn: 4, endColumn: 8, current: true }] });
      assert(next.getSelection()?.startColumn === 4, "second match on same row did not navigate");
      const button = container.querySelector("button")!;
      button.click();
      assert(calls.join() === "hunk-0:stage", "hunk action used display line identity");
      await review.update({ rows: [], language: "plaintext", actions: [] });
      button.click();
      assert(calls.length === 1, "removed hunk button remained actionable");
      assert(next.getModel()!.getValue() === "", "empty refresh kept old patch content");
    } finally { review.dispose(); container.remove(); }
    assert(monacoEditor.getModels().length === before, "closed diff retained models");
  });
  await check("diff updates discard stale tokenizer activation and preserve main editor", async () => {
    const before = monacoEditor.getModels().length;
    const container = document.createElement("div");
    container.style.cssText = "height:300px;width:800px";
    document.body.append(container);
    const review = mountDiffReview(container);
    const row = (text: string): ReviewRow => ({ id: text, oldLine: 1, newLine: 1, left: text, right: text, kind: "context" });
    try {
      await Promise.all([
        review.update({ rows: [row("old")], language: "python" }),
        review.update({ rows: [row("latest")], language: "plaintext" }),
      ]);
      assert(review.editor.getModifiedEditor().getModel()!.getValue() === "latest", "old tokenizer activation won refresh race");
      assert(review.editor.getModifiedEditor().getModel()!.getLanguageId() === "plaintext", "stale refresh changed syntax");
    } finally { review.dispose(); container.remove(); }
    await window.lithe.showDiff({ rows: [row("runtime")], language: "plaintext" });
    window.lithe.hideDiff();
    assert(monacoEditor.getModels().length === before, "runtime diff cleanup retained models");
    assert(!document.getElementById("diff-review"), "runtime left a covering diff surface");
    assert(document.getElementById("editor")!.style.display !== "none", "diff hid main editor after dismissal");
  });
  await check("diff search reveals a source row inside collapsed context", async () => {
    const container = document.createElement("div");
    container.style.cssText = "position:absolute;inset:0;height:400px;width:1000px";
    document.body.append(container);
    const review = mountDiffReview(container);
    const rows: ReviewRow[] = Array.from({ length: 100 }, (_, index) => ({
      id: `row-${index}`, oldLine: index + 101, newLine: index + 101,
      left: `value ${index}`, right: index === 0 ? "changed" : `value ${index}`,
      kind: index === 0 ? "changed" : "context",
    }));
    let subscription: { dispose(): void } | undefined;
    let deadline: ReturnType<typeof setTimeout> | undefined;
    try {
      const computed = new Promise<void>((resolve, reject) => {
        deadline = setTimeout(() => reject(new Error("Diff computation exceeded 5 seconds")), 5000);
        subscription = review.editor.onDidUpdateDiff(() => {
          if (review.editor.getLineChanges()?.length) resolve();
        });
      });
      await Promise.all([review.update({ rows, language: "plaintext", collapse: true }), computed]);
      review.select({ revealID: "row-50", searchIDs: ["row-50"] });
      const next = review.editor.getModifiedEditor();
      assert(next.getVisibleRanges().some(range => range.startLineNumber <= 51 && range.endLineNumber >= 51),
        "search target stayed hidden inside collapsed context");
    } finally {
      if (deadline !== undefined) clearTimeout(deadline);
      subscription?.dispose(); review.dispose(); container.remove();
    }
  });
  await check("inline diff navigation scrolls to a removed source row", async () => {
    const container = document.createElement("div");
    container.style.cssText = "position:absolute;inset:0;height:400px;width:1000px";
    document.body.append(container);
    const review = mountDiffReview(container);
    const rows: ReviewRow[] = Array.from({ length: 150 }, (_, index) => ({
      id: `inline-${index}`, oldLine: index + 1, newLine: index === 110 ? null : index + 1,
      left: `value ${index}`, right: index === 110 ? null : `value ${index}`,
      kind: index === 110 ? "removal" : "context",
    }));
    let subscription: { dispose(): void } | undefined;
    let deadline: ReturnType<typeof setTimeout> | undefined;
    try {
      const computed = new Promise<void>((resolve, reject) => {
        deadline = setTimeout(() => reject(new Error("Inline diff computation exceeded 5 seconds")), 5000);
        subscription = review.editor.onDidUpdateDiff(() => {
          if (review.editor.getLineChanges()?.length) resolve();
        });
      });
      await Promise.all([review.update({ rows, language: "plaintext", sideBySide: false, collapse: false }), computed]);
      review.select({ revealID: "inline-110", searchIDs: ["inline-110"] });
      const old = review.editor.getOriginalEditor(), next = review.editor.getModifiedEditor();
      assert(old.getPosition()?.lineNumber === 111, "removed source row lost its cursor identity");
      const targetTop = old.getTopForLineNumber(111);
      assert(next.getScrollTop() > 0 && targetTop >= next.getScrollTop()
        && targetTop < next.getScrollTop() + next.getLayoutInfo().height,
        "removed source row remained outside the inline viewport");
    } finally {
      if (deadline !== undefined) clearTimeout(deadline);
      subscription?.dispose(); review.dispose(); container.remove();
    }
  });
  await check("Windows source adapter shares one mirror and resets external undo versions", async () => {
    const text = "first\r\nvalue\nlast\rtail";
    const model = monacoEditor.createModel(text, "plaintext");
    try {
      const source = acquireEditorModelSource(model, text);
      assert(acquireEditorModelSource(model, text) === source, "multiple views created competing source mirrors");
      model.pushEditOperations([], [{ range: new Range(2, 1, 2, 6), text: "new" }], () => null);
      assert(source.content === "first\r\nnew\nlast\rtail", "Windows mirror normalized untouched source newlines");
      const position = sourcePositionAt(source.content, source.content.indexOf("tail"));
      assert(position.line === 3 && position.column === 0, "Windows LSP source position ignored CR");
      source.replace("external\rnew\n");
      assert(source.lastChange?.external, "external replacement escaped source suppression");
      model.pushEditOperations([], [{ range: new Range(2, 1, 2, 4), text: "edited" }], () => null);
      assert(source.content === "external\redited\n", "reset model version restored an unrelated old source snapshot");
      await model.undo();
      assert(source.content === "external\rnew\n", "undo after external replacement lost original bytes");
    } finally { model.dispose(); }
  });
  await check("shared source history follows real Monaco grouped undo and branching", async () => {
    const text = "first\r\n😀middle\rlast\n";
    const model = monacoEditor.createModel(text, "plaintext");
    const source = acquireEditorModelSource(model, text);
    const edit = (value: string) => model.pushEditOperations([], [
      { range: new Range(1, 1, 1, model.getLineMaxColumn(1)), text: value },
    ], () => null);
    try {
      edit("kept");
      model.pushStackElement();
      const kept = source.content;
      edit("discarded"); edit("grouped discarded");
      model.pushStackElement();
      await model.undo();
      assert(source.content === kept, "grouped undo did not restore the earlier root");
      edit("branched");
      model.pushStackElement();
      const branched = source.content;
      await model.undo();
      assert(source.content === kept, "new branch lost its undo parent");
      await model.undo();
      assert(source.content === text, "branch cleanup evicted original mixed-newline bytes");
      await model.redo(); await model.redo();
      assert(source.content === branched, "branch cleanup corrupted redo");
      assert(!model.canRedo(), "Monaco unexpectedly retained the abandoned redo branch");
    } finally { model.dispose(); }
  });
  const source = "class Probe {\r\n    // 中文 😀\r\n}\r\n";
  await check("Java tokenizer is ready before the first model opens", async () => {
    const tokens = monacoEditor.tokenize("public class Probe {}", "java")[0];
    assert(tokens.some(token => token.type.startsWith("keyword")), "Java opened without its tokenizer");
  });
  await check("shared language tokenizers are ready on first non-Java activation", async () => {
    const examples = [
      ["typescriptreact", "typescript", "const answer: number = 42;"],
      ["python", "python", "def answer(): return 42"],
      ["rust", "rust", "pub fn answer() -> u32 { 42 }"],
      ["jsonc", "json", '{"answer": 42}'],
      ["xml", "xml", '<answer value="42"/>'],
      ["yaml", "yaml", "answer: true"],
      ["zig", "zig", "const answer: u32 = 42;"],
      ["text", "plaintext", "unformatted text"],
    ];
    for (const [language, expected, text] of examples) {
      const id = `language-${language}`;
      await window.lithe.activate({ id, text, revision: 0, language, readonly: true });
      const model = monacoEditor.getEditors()[0].getModel()!;
      assert(model.getLanguageId() === expected, `wrong language for ${language}`);
      assert(model.getValue() === text, `activation changed ${language} text`);
      if (expected !== "plaintext") {
        const tokens = monacoEditor.tokenize(text, expected)[0];
        assert(tokens.some(token => token.type.length > 0), `missing first-open tokenizer for ${language}`);
      }
      await window.lithe.retain([]);
    }
  });
  await check("native filename activation selects syntax without a language server", async () => {
    for (const [filename, expected] of [["main.rs", "rust"], ["settings.json", "json"], ["Dockerfile", "dockerfile"], ["unknown.custom", "plaintext"]]) {
      await window.lithe.activate({ id: filename, filename, text: "// sample", revision: 0, readonly: true });
      const model = monacoEditor.getEditors()[0].getModel()!;
      assert(model.getLanguageId() === expected, `filename ${filename} selected ${model.getLanguageId()}`);
      await window.lithe.retain([]);
    }
  });
  await send({ type: "open", text: source });
  await window.lithe.activate({ id: "A", text: source, revision: 0, language: "java", readonly: false, focus: false });
  const editor = monacoEditor.getEditors()[0];
  const model = editor.getModel()!;
  await check("workbench edit queue and save barrier preserve CRLF and UTF-16", async () => {
    editor.executeEdits("integration", [{ range: new Range(2, 8, 2, 10), text: "日本語🙂" }]);
    editor.pushUndoStop();
    // Freeze starts immediately, before the native edit acknowledgment.
    const snapshot = await window.lithe.freeze("A");
    assert(snapshot.text.replace(/\r\n|\r/g, "\n") === model.getValue(), "freeze lost the last keystroke");
    assert(snapshot.text.includes("\r\n"), "CRLF was normalized on save");
    await send({ type: "save", revision: snapshot.revision, expected: snapshot.text });
    window.lithe.unlock("A");
  });
  await check("save barrier admits already queued input before freezing", async () => {
    const id = "queued-input", text = "before";
    await send({ type: "open", id, text });
    await window.lithe.activate({ id, text, revision: 0, language: "plaintext", readonly: false, focus: true });
    const model = editor.getModel()!;
    editor.setPosition({ lineNumber: 1, column: model.getLineMaxColumn(1) });
    const typed = new Promise<void>(resolve => setTimeout(() => {
      editor.trigger("integration", "type", { text: "_ALIVE" });
      resolve();
    }, 0));
    const snapshotPromise = window.lithe.freeze(id, "queued-input-save");
    await typed;
    const snapshot = await snapshotPromise;
    assert(snapshot.text === "before_ALIVE", "freeze made the editor read-only before queued input was delivered");
    assert(snapshot.barrierDrained && snapshot.pendingEdits === 0 && snapshot.operationID === "queued-input-save",
      "freeze returned before its snapshot edit queue drained");
    // The revision barrier must not make the editor read-only: input delivered
    // while the native save call is in flight remains a newer dirty revision.
    editor.trigger("integration", "type", { text: "_DURING_SAVE" });
    assert(model.getValue() === "before_ALIVE_DURING_SAVE", "save barrier dropped input delivered during synchronization");
    // A delayed unlock from an older save must not release the current token.
    window.lithe.unlock(id, "older-save");
    await assertRejects(() => window.lithe.freeze(id, "next-save"), "stale unlock released a newer save barrier");
    window.lithe.unlock(id, "queued-input-save");
    editor.trigger("integration", "type", { text: "_OK" });
    assert(model.getValue() === "before_ALIVE_DURING_SAVE_OK", "matching unlock did not preserve editing");
    const finalSnapshot = await window.lithe.freeze(id);
    assert(finalSnapshot.text === "before_ALIVE_DURING_SAVE_OK" && finalSnapshot.barrierDrained && finalSnapshot.pendingEdits === 0,
      "edits delivered during synchronization did not reach the next save snapshot");
    const repeatedSnapshot = await window.lithe.freeze(id);
    assert(repeatedSnapshot.operationID === finalSnapshot.operationID,
      "repeated legacy save probe replaced its active synchronization token");
    await window.lithe.retain(["A"]);
  });
  await check("workbench tab switch preserves model and undo history", async () => {
    await window.lithe.activate({ id: "B", text: "class Other {}", revision: 0, language: "java", readonly: false });
    const activation = await window.lithe.activate({ id: "A", readonly: false });
    assert(activation.reused, "cached tab required a full-text transfer");
    assert(editor.getModel() === model, "tab switch recreated model");
    await model.undo();
    const snapshot = await window.lithe.freeze("A");
    assert(snapshot.text === source, "undo was lost across tab switch");
    await send({ type: "save", revision: snapshot.revision, expected: snapshot.text });
    window.lithe.unlock("A");
  });
  await check("workbench diagnostics and closed model cleanup", async () => {
    await window.lithe.markers("A", [{ startLineNumber: 1, endLineNumber: 1, startColumn: 1, endColumn: 6, severity: 4, message: "fixture" }]);
    assert(monacoEditor.getModelMarkers({ resource: model.uri }).length === 1, "diagnostics missing");
    await window.lithe.retain(["A"]);
    assert(monacoEditor.getModel(Uri.parse("lithe://document/B")) === null, "closed tab model leaked");
  });
  await check("workbench external edit rejects stale revision", async () => {
    let rejected = false;
    try { await window.lithe.replace({ id: "A", previousRevision: -1, revision: 99, text: "wrong" }); }
    catch { rejected = true; }
    assert(rejected, "stale external content replaced editor");
    const snapshot = await window.lithe.freeze("A");
    assert(snapshot.text === source, "rejected update changed text");
    window.lithe.unlock("A");
  });
  await check("workbench bulk synchronization freezes every retained model", async () => {
    const snapshots = await window.lithe.freezeAll();
    assert(snapshots.A.text === source, "bulk snapshot mismatch");
    await window.lithe.retain([]);
    assert(monacoEditor.getModels().length === 0, "bulk close retained models");
  });
  await check("large Java model opens once and reuses its view state", async () => {
    const text = "class Large {\n" + Array.from({ length: 10_000 }, (_, i) => `    int field${i}; // 中文 😀`).join("\n") + "\n}";
    const opened = await window.lithe.activate({ id: "large", text, revision: 0, language: "java", readonly: false });
    assert(!opened.reused && opened.lines === 10_002, "large model was not created correctly");
    await window.lithe.tokenizationReady();
    assert(!window.lithe.tokenizationStatus().failed, "background tokenizer failed");
    const large = editor.getModel();
    editor.setPosition({ lineNumber: 5000, column: 8 });
    await window.lithe.activate({ id: "other", text: "class Other {}", revision: 0, language: "java", readonly: false });
    await window.lithe.activate({ id: "large", readonly: false });
    assert(editor.getModel() === large && editor.getPosition()?.lineNumber === 5000, "cached model/view state was lost");
    await window.lithe.retain([]);
  });
  await check("simultaneous views share edits and undo but keep independent selection", async () => {
    const text = "class Shared {}";
    await send({ type: "open", text });
    await window.lithe.activate({ id: "shared", text, revision: 0, language: "java", readonly: false });
    const container = document.createElement("div");
    container.style.cssText = "position:absolute;left:50%;top:0;width:50%;height:100%";
    document.body.append(container);
    try {
      await window.lithe.attachSurface("right", container, { id: "shared" });
      const secondary = monacoEditor.getEditors().find(view => view !== editor)!;
      assert(secondary.getModel() === editor.getModel(), "split cloned the document model");
      editor.setPosition({ lineNumber: 1, column: 2 });
      secondary.setPosition({ lineNumber: 1, column: 8 });
      secondary.focus();
      assert(editor.getPosition()?.column === 2, "secondary moved primary cursor");
      secondary.pushUndoStop();
      secondary.executeEdits("integration", [{ range: new Range(1, 7, 1, 13), text: "Renamed" }]);
      secondary.pushUndoStop();
      let snapshot = await window.lithe.freeze("shared");
      assert(snapshot.text === "class Renamed {}", "secondary edit was lost or applied twice");
      assert(!editor.getOption(monacoEditor.EditorOption.readOnly) && !secondary.getOption(monacoEditor.EditorOption.readOnly),
        "save revision barrier made a shared view read-only");
      await send({ type: "save", revision: snapshot.revision, expected: snapshot.text });
      window.lithe.unlock("shared");
      await editor.getModel()!.undo();
      snapshot = await window.lithe.freeze("shared");
      assert(snapshot.text === text, "undo history was not shared across views");
      await send({ type: "save", revision: snapshot.revision, expected: text });
      window.lithe.unlock("shared");
      window.lithe.detachSurface("right");
      assert(editor.getModel()?.getValue() === text, "closing split disposed shared model");
      const pendingAttach = window.lithe.attachSurface("right", container, { id: "shared" });
      window.lithe.detachSurface("right");
      await pendingAttach;
      assert(monacoEditor.getEditors().length === 1, "late attach resurrected a closed split");
      await window.lithe.retain([]);
      assert(monacoEditor.getModels().length === 0, "closing document leaked split model");
    } finally {
      window.lithe.detachSurface("right");
      container.remove();
    }
  });
  await check("native split layout opens a second document and restores the primary width", async () => {
    await window.lithe.activate({ id: "left-layout", text: "left", revision: 0, language: "plaintext", readonly: true });
    await window.lithe.showSecondary({ id: "right-layout", text: "right", revision: 0, language: "plaintext", readonly: true });
    assert(monacoEditor.getEditors().length === 2, "native split did not create two views");
    assert(editor.getModel()?.getValue() === "left", "split replaced primary document");
    const secondary = monacoEditor.getEditors().find(view => view !== editor)!;
    assert(secondary.getModel()?.getValue() === "right", "split lost its independent document");
    await window.lithe.navigate({ id: "right-layout", line: 0, column: 2 });
    assert(secondary.getPosition()?.column === 3, "navigation did not reach the secondary view");
    assert(editor.getModel()?.getValue() === "left", "secondary navigation replaced primary document");
    assert(document.getElementById("editor")?.style.width === "50%", "primary width did not enter split layout");
    window.lithe.hideSecondary();
    assert(monacoEditor.getEditors().length === 1, "split view was not disposed");
    assert(document.getElementById("editor")?.style.width === "100%", "primary width was not restored");
    assert(editor.getModel()?.getValue() === "left", "split close changed primary document");
    await window.lithe.retain([]);
  });
  await check("modal preview restores the main caret while sharing undo", async () => {
    const text = "class Preview {}";
    await send({ type: "open", text });
    await window.lithe.activate({ id: "preview-state", text, revision: 0, language: "java", readonly: false });
    editor.setPosition({ lineNumber: 1, column: 3 });
    await window.lithe.suspendMain();
    await window.lithe.activate({ id: "preview-state", readonly: false });
    await window.lithe.find({ id: "preview-state", query: "Preview", matchCase: true });
    editor.setPosition({ lineNumber: 1, column: 10 });
    editor.pushUndoStop();
    editor.executeEdits("preview", [{ range: new Range(1, 7, 1, 14), text: "Changed" }]);
    editor.pushUndoStop();
    await window.lithe.activate({ id: "preview-state", readonly: false });
    await window.lithe.restoreMain();
    assert(editor.getPosition()?.column === 3, "modal preview lost main caret");
    const findState = (editor.getContribution("editor.contrib.findController") as any).getState();
    assert(!findState.isRevealed, "preview find widget leaked into main editor");
    assert(editor.getModel()?.getValue() === "class Changed {}", "modal preview lost edits");
    await editor.getModel()!.undo();
    const snapshot = await window.lithe.freeze("preview-state");
    assert(snapshot.text === text, "modal preview lost shared undo");
    await send({ type: "save", revision: snapshot.revision, expected: text });
    await window.lithe.retain([]);
  });
  await check("modal preview restores an existing main search query and options", async () => {
    await window.lithe.activate({ id: "main-find", text: "original Preview", revision: 0, language: "plaintext", readonly: true });
    await window.lithe.find({ id: "main-find", query: "original", matchCase: true, wholeWord: true });
    await window.lithe.suspendMain();
    await window.lithe.find({ id: "main-find", query: "Preview", regex: true });
    await window.lithe.restoreMain();
    const state = (editor.getContribution("editor.contrib.findController") as any).getState();
    assert(state.isRevealed && state.searchString === "original", "existing main search was lost");
    assert(state.matchCase && state.wholeWord && !state.isRegex, "preview search options leaked into main");
    state.change({ isRevealed: false }, false);
    await window.lithe.retain([]);
  });
  await check("preview search targets its surface and preserves other pane search state", async () => {
    await window.lithe.activate({ id: "find-left", text: "left LEFT", revision: 0, language: "plaintext", readonly: true });
    await window.lithe.showSecondary({ id: "find-right", text: "right RIGHT", revision: 0, language: "plaintext", readonly: true });
    try {
      const secondary = monacoEditor.getEditors().find(view => view !== editor)!;
      await window.lithe.find({ id: "find-left", query: "left", matchCase: false });
      await window.lithe.find({ id: "find-right", query: "RIGHT", matchCase: true, wholeWord: true, regex: true });
      const state = (view: typeof editor) => (view.getContribution("editor.contrib.findController") as any).getState();
      assert(state(editor).searchString === "left", "preview search changed primary query");
      assert(state(secondary).searchString === "RIGHT", "preview query did not reach secondary");
      assert(state(secondary).matchCase && state(secondary).wholeWord && state(secondary).isRegex, "preview options were lost");
      await window.lithe.find({ id: "closed-preview", query: "wrong" });
      await window.lithe.find({ surface: "missing", query: "wrong" });
      assert(state(secondary).searchString === "RIGHT" && state(editor).searchString === "left", "closed preview searched another document");
    } finally {
      window.lithe.hideSecondary();
      await window.lithe.retain([]);
    }
  });
  await check("mixed source newlines survive native save, undo and redo", async () => {
    const original = "first\r\n中文😀\nthird\rfourth";
    await send({ type: "open", text: original });
    await window.lithe.activate({ id: "mixed", text: original, revision: 0, language: "plaintext", readonly: false });
    const model = editor.getModel()!;
    editor.pushUndoStop();
    editor.executeEdits("integration", [{ range: new Range(2, 1, 2, 5), text: "hello\nworld" }]);
    editor.pushUndoStop();
    const edited = "first\r\nhello\r\nworld\nthird\rfourth";
    let snapshot = await window.lithe.freeze("mixed");
    assert(snapshot.text === edited, "mixed newline edit changed untouched separators");
    await send({ type: "save", revision: snapshot.revision, expected: edited });
    window.lithe.unlock("mixed");
    await model.undo();
    snapshot = await window.lithe.freeze("mixed");
    assert(snapshot.text === original, "undo did not restore original newline bytes");
    await send({ type: "save", revision: snapshot.revision, expected: original });
    window.lithe.unlock("mixed");
    await model.redo();
    snapshot = await window.lithe.freeze("mixed");
    assert(snapshot.text === edited, "redo changed newline bytes");
    await send({ type: "save", revision: snapshot.revision, expected: edited });
    await window.lithe.retain([]);
  });
  await check("source patches beside emoji cross the native bridge without split surrogates", async () => {
    const original = "😀x🙂";
    await send({ type: "open", text: original });
    await window.lithe.activate({ id: "emoji", text: original, revision: 0, language: "plaintext", readonly: false });
    editor.executeEdits("integration", [{ range: new Range(1, 3, 1, 4), text: "中" }]);
    const snapshot = await window.lithe.freeze("emoji");
    assert(snapshot.text === "😀中🙂", "native bridge damaged neighboring emoji");
    await send({ type: "save", revision: snapshot.revision, expected: snapshot.text });
    await window.lithe.retain([]);
  });
  await check("bare CR boundary deletion keeps native and model line counts equal", async () => {
    const original = "a\rx\nb";
    await send({ type: "open", text: original });
    await window.lithe.activate({ id: "bare", text: original, revision: 0, language: "plaintext", readonly: false });
    const model = editor.getModel()!;
    editor.pushUndoStop();
    editor.executeEdits("integration", [{ range: new Range(2, 1, 2, 2), text: "" }]);
    editor.pushUndoStop();
    let snapshot = await window.lithe.freeze("bare");
    assert(snapshot.text === "a\n\nb" && model.getLineCount() === 3, "bare CR and LF collapsed a line");
    await send({ type: "save", revision: snapshot.revision, expected: snapshot.text });
    window.lithe.unlock("bare");
    await model.undo();
    snapshot = await window.lithe.freeze("bare");
    assert(snapshot.text === original, "bare CR boundary undo lost bytes");
    await send({ type: "save", revision: snapshot.revision, expected: original });
    await window.lithe.retain([]);
  });
  await check("image paste uses a Monaco undo transaction and preserves source newlines", async () => {
    const text = "before\r\nreplace\r\nafter";
    await send({ type: "open", text });
    await window.lithe.activate({ id: "image-paste", text, revision: 0, language: "markdown", readonly: false });
    const model = editor.getModel()!;
    editor.setSelection(new Range(2, 1, 2, 8));
    let deadline: ReturnType<typeof setTimeout> | undefined;
    let changed: ReturnType<typeof model.onDidChangeContent> | undefined;
    try {
      const inserted = new Promise<void>((resolve, reject) => {
        deadline = setTimeout(() => reject(new Error("Image insertion exceeded 5 seconds")), 5000);
        changed = model.onDidChangeContent(() => resolve());
      });
      const clipboard = new DataTransfer();
      clipboard.items.add(new File(["fixture"], "image.png", { type: "image/png" }));
      const event = new ClipboardEvent("paste", { clipboardData: clipboard, bubbles: true, cancelable: true });
      // WebKit does not populate clipboardData from a synthetic event's init.
      // Supply the fixture explicitly; OS clipboard delivery is a separate UI check.
      Object.defineProperty(event, "clipboardData", { value: clipboard });
      editor.getDomNode()!.dispatchEvent(event);
      // Mutate the event's backing clipboard after dispatch, before the host
      // preflight completes. The native fixture requires the original bytes.
      clipboard.items.clear();
      clipboard.items.add(new File(["changed"], "other.png", { type: "image/png" }));
      assert(event.defaultPrevented, "image paste fell through to Monaco's text paste");
      await inserted;
      const snapshot = await window.lithe.freeze("image-paste");
      assert(snapshot.text === "before\r\n\r\n\r\n![fixture](assets/image.png)\r\n\r\n\r\nafter", "image edit corrupted source newlines or selection");
      window.lithe.unlock("image-paste");
      await model.undo();
      const undone = await window.lithe.freeze("image-paste");
      assert(undone.text === text, "image paste was not a single undoable source edit");
      window.lithe.unlock("image-paste");
      const plain = new DataTransfer();
      plain.setData("text/plain", "ordinary text");
      const ordinary = new ClipboardEvent("paste", { clipboardData: plain, bubbles: true, cancelable: true });
      Object.defineProperty(ordinary, "clipboardData", { value: plain });
      editor.getDomNode()!.dispatchEvent(ordinary);
      assert(!ordinary.defaultPrevented, "image interceptor swallowed ordinary text");
    } finally {
      if (deadline !== undefined) clearTimeout(deadline);
      changed?.dispose();
      await window.lithe.retain([]);
    }
  });
  for (const transition of ["switch", "close", "edit", "freeze"] as const) {
    await check(`image import rejects a late insertion after ${transition}`, async () => {
      const text = "original";
      await send({ type: "open", text });
      await window.lithe.activate({ id: "late-image", text, revision: 0, language: "markdown", readonly: false });
      const original = editor.getModel()!;
      let deadline: ReturnType<typeof setTimeout> | undefined;
      const bounded = async (message: object) => {
        try {
          return await Promise.race([send(message), new Promise<never>((_, reject) => {
            deadline = setTimeout(() => reject(new Error(`Image ${transition} gate exceeded 5 seconds`)), 5000);
          })]);
        } finally { if (deadline !== undefined) clearTimeout(deadline); }
      };
      try {
        await send({ type: "holdImagePaste" });
        const clipboard = new DataTransfer();
        clipboard.items.add(new File(["fixture"], "image.png", { type: "image/png" }));
        const event = new ClipboardEvent("paste", { bubbles: true, cancelable: true });
        Object.defineProperty(event, "clipboardData", { value: clipboard });
        editor.getDomNode()!.dispatchEvent(event);
        await bounded({ type: "awaitImagePaste" });
        // Hold the import, perform the user transition, then deliver its result.
        if (transition === "switch") {
          await window.lithe.activate({ id: "other-image", text: "other", revision: 0, language: "markdown", readonly: false });
        } else if (transition === "close") {
          await window.lithe.retain([]);
        } else if (transition === "edit") {
          editor.executeEdits("integration", [{ range: new Range(1, 1, 1, 1), text: "new " }]);
        } else {
          await window.lithe.freeze("late-image");
        }
        await send({ type: "releaseImagePaste" });
        const notification = await bounded({ type: "awaitImagePasteNotification" });
        assert(notification.message.includes("document changed"), "cancelled insertion did not explain the saved image");
        if (transition === "close") assert(original.isDisposed(), "late paste resurrected the closed model");
        else assert(original.getValue() === (transition === "edit" ? "new original" : text), "late image overwrote the original document");
        if (transition === "switch") assert(editor.getModel()!.getValue() === "other", "late image modified the newly selected document");
      } finally {
        await send({ type: "resetImagePaste" });
        window.lithe.unlock("late-image");
        await window.lithe.retain([]);
      }
    });
  }
  await check("Java hierarchy markers route both directions and invalidate after edits and renames", async () => {
    const text = "class Child extends Parent {\n}";
    await send({ type: "open", text });
    await window.lithe.activate({ id: "navigation", text, revision: 0, language: "java", readonly: false });
    const model = editor.getModel()!;
    try {
      await window.lithe.refreshJavaNavigation();
      const markers = model.getAllDecorations().filter(value => value.options.glyphMarginClassName?.includes("lithe-java-navigation"));
      assert(markers.length === 2 && markers[0].options.glyphMarginClassName?.includes("both"), "same-line hierarchy directions were lost");
      assert(markers[0].options.glyphMargin?.position === monacoEditor.GlyphMarginLane.Left, "hierarchy marker occupied the breakpoint lane");
      assert(markers[0].options.glyphMarginClassName?.includes("up-interface") && markers[0].options.glyphMarginClassName?.includes("down-inheritance"), "first-line relation icons were lost");
      assert(markers[1].options.glyphMarginClassName?.includes("up-inheritance") && markers[1].options.glyphMarginClassName?.includes("down-interface"), "second-line relation icons were lost");
      editor.render(true);
      const glyphs = editor.getDomNode()!.querySelectorAll<HTMLElement>(".lithe-java-navigation");
      assert(glyphs.length >= 2, "hierarchy glyphs did not render");
      for (const glyph of glyphs) for (const pseudo of ["::before", "::after"]) {
        assert(getComputedStyle(glyph, pseudo).backgroundImage.includes("data:image/svg+xml"), "native navigation asset was not bundled into the glyph");
      }
      assert(model.getValue() === text && !model.canUndo(), "hierarchy rendering changed document text");
      editor.setPosition({ lineNumber: 1, column: 1 });
      await editor.getAction("lithe.javaNavigation.up")!.run();
      await editor.getAction("lithe.javaNavigation.down")!.run();
      assert((await send({ type: "javaNavigationActions" })).markers.join() === "super,implementations", "hierarchy actions resolved the wrong direction");
      editor.executeEdits("integration", [{ range: new Range(1, 1, 1, 1), text: "// inserted\n" }]);
      await editor.getAction("lithe.javaNavigation.up")!.run();
      assert((await send({ type: "javaNavigationActions" })).markers.length === 2, "old hierarchy marker remained actionable after an edit");
      await window.lithe.activate({ id: "navigation", filename: "child.txt", readonly: false });
      await window.lithe.refreshJavaNavigation();
      assert(!model.getAllDecorations().some(value => value.options.glyphMarginClassName?.includes("lithe-java-navigation")), "non-Java rename retained hierarchy arrows");
    } finally { await window.lithe.retain([]); }
  });
  for (const ending of ["edit", "rename", "close", "supersede"]) {
    await check(`delayed Java hierarchy response cannot survive ${ending}`, async () => {
      await send({ type: "open", text: "class Child {}" });
      await window.lithe.activate({ id: "navigation-race", text: "class Child {}", revision: 0, language: "java", readonly: false });
      await window.lithe.refreshJavaNavigation();
      const model = editor.getModel()!;
      let pending: Promise<unknown> | undefined;
      try {
        await send({ type: "holdNavigation" });
        pending = window.lithe.refreshJavaNavigation();
        let deadline: ReturnType<typeof setTimeout> | undefined;
        try {
          await Promise.race([send({ type: "awaitNavigation" }), new Promise((_, reject) => {
            deadline = setTimeout(() => reject(new Error("Hierarchy request never reached its gate")), 2000);
          })]);
        } finally { clearTimeout(deadline); }
        if (ending === "edit") editor.executeEdits("integration", [{ range: new Range(1, 1, 1, 1), text: "//new\n" }]);
        if (ending === "rename") await window.lithe.activate({ id: "navigation-race", filename: "child.txt", readonly: false });
        if (ending === "close") await window.lithe.retain([]);
        if (ending === "supersede") await window.lithe.refreshJavaNavigation();
        await send({ type: "releaseNavigation", stale: true });
        await pending;
        if (ending === "close") assert(model.isDisposed(), "closed hierarchy model survived");
        else {
          editor.setPosition({ lineNumber: 1, column: 1 });
          const before = (await send({ type: "javaNavigationActions" })).markers.length;
          await editor.getAction("lithe.javaNavigation.down")!.run();
          const actions = (await send({ type: "javaNavigationActions" })).markers;
          assert(actions.at(-1) !== "stale", "old hierarchy response became actionable");
          assert(actions.length === before + (ending === "supersede" ? 1 : 0), "hierarchy action validity did not follow latest state");
        }
      } finally {
        await send({ type: "releaseNavigation" });
        await pending;
        await window.lithe.retain([]);
      }
    });
  }
  await check("macOS product shortcuts edit through Monaco and preserve undo and CRLF", async () => {
    const source = "one\r\ntwo\r\nthree";
    await send({ type: "open", text: source });
    await window.lithe.activate({ id: "keymap", text: source, revision: 0, language: "java", readonly: false });
    const model = editor.getModel()!;
    const press = (init: KeyboardEventInit) => {
      editor.focus();
      const input = editor.getDomNode()!.querySelector("textarea")!;
      assert(input, "Monaco input target is missing");
      input.dispatchEvent(new KeyboardEvent("keydown", { bubbles: true, cancelable: true, ...init }));
    };
    const assertSource = async (expected: string) => {
      const snapshot = await window.lithe.freeze("keymap");
      assert(snapshot.text === expected, `Shortcut produced ${JSON.stringify(snapshot.text)}, expected ${JSON.stringify(expected)}`);
      window.lithe.unlock("keymap");
    };
    try {
      editor.setPosition({ lineNumber: 2, column: 2 });
      press({ key: "D", code: "KeyD", keyCode: 68, metaKey: true, modifierCapsLock: true });
      await assertSource("one\r\ntwo\r\ntwo\r\nthree");
      await model.undo(); await assertSource(source);
      editor.setSelection(new Range(2, 2, 2, 4));
      press({ key: "d", code: "KeyD", keyCode: 68, metaKey: true });
      await assertSource("one\r\ntwowo\r\nthree");
      await model.undo(); await assertSource(source);
      editor.setPosition({ lineNumber: 2, column: 1 });
      press({ key: "ArrowUp", code: "ArrowUp", keyCode: 38, altKey: true, shiftKey: true, modifierCapsLock: true });
      await assertSource("two\r\none\r\nthree");
      await model.undo(); await assertSource(source);
      editor.setPosition({ lineNumber: 2, column: 1 });
      press({ key: "ArrowDown", code: "ArrowDown", keyCode: 40, altKey: true, shiftKey: true, location: 3 });
      await assertSource("one\r\nthree\r\ntwo");
      await model.undo(); await assertSource(source);
      editor.setPosition({ lineNumber: 1, column: 1 });
      press({ key: "/", code: "Slash", keyCode: 191, metaKey: true, modifierCapsLock: true });
      await assertSource("// one\r\ntwo\r\nthree");
      await model.undo(); await assertSource(source);
      await window.lithe.updateDocument({ id: "keymap", filename: "readonly.java", locationRevision: 0, readonly: true });
      press({ key: "d", code: "KeyD", keyCode: 68, metaKey: true });
      assert(model.getValue() === "one\ntwo\nthree", "read-only shortcut changed source");
      await window.lithe.updateDocument({ id: "keymap", filename: "writable.java", locationRevision: 0, readonly: false });
      editor.setPosition({ lineNumber: 1, column: 1 });
      editor.trigger("integration", "type", { text: "X" });
      assert(model.getValue().startsWith("X"), "permission refresh did not restore editing");
    } finally { await window.lithe.retain([]); }
  });
  await check("blame metadata escapes authors and follows model and split lifecycles", async () => {
    const text = "first\nsecond\nthird";
    await send({ type: "open", text });
    await window.lithe.activate({ id: "blame", text, revision: 0, language: "plaintext", readonly: false });
    const model = editor.getModel()!;
    const author = '<img src=x onerror="throw 1"> & author';
    const state = { revision: 0, markers: [], blameVisible: true, blame: [
      { line: 1, commit: "abc12345", author, date: "2026-01-01" },
      { line: 2, commit: "abc12345", author, date: "2026-01-01" },
      { line: 3, commit: "def67890", author: "Other", date: "2026-01-02" },
    ] };
    const container = document.createElement("div");
    container.style.cssText = "height:200px;width:600px";
    document.body.append(container);
    try {
      await window.lithe.gitState("blame", state);
      editor.render(true);
      const label = editor.getDomNode()!.querySelector(".lithe-blame")!;
      assert(label?.textContent === `${author} · 2026-01-01`, "blame author was not displayed as literal text");
      assert(!label.querySelector("img"), "blame author injected markup");
      const numbers = editor.getRawOptions().lineNumbers as (line: number) => string;
      const repeated = document.createElement("div");
      repeated.innerHTML = numbers(2);
      assert(repeated.querySelector(".lithe-blame")?.textContent === "\u200b", "same-commit metadata was repeated on every line");
      assert(model.getValue() === text && !model.canUndo(), "blame presentation modified source or undo history");
      editor.setPosition({ lineNumber: 3, column: 1 });
      await editor.getAction("lithe.git.blameCommit")!.run();
      assert((await send({ type: "blameCommits" })).commits.join() === "def67890", "blame command used a different line's commit");
      await window.lithe.attachSurface("blame-split", container, { id: "blame" });
      const split = monacoEditor.getEditors().find(value => value !== editor)!;
      assert(typeof split.getRawOptions().lineNumbers === "function", "new split did not inherit blame state");
      await window.lithe.activate({ id: "blame-other", text: "other", revision: 0, language: "plaintext", readonly: false });
      assert(editor.getRawOptions().lineNumbers === "on", "blame metadata leaked into another tab");
      assert(typeof split.getRawOptions().lineNumbers === "function", "switching the primary cleared the split's blame");
      await window.lithe.gitState("blame", { revision: 0, markers: [], blameVisible: false, blame: [] });
      assert(split.getRawOptions().lineNumbers === "on" && split.getRawOptions().lineNumbersMinChars === 5, "closing blame left a wide gutter");
      await split.getAction("lithe.git.blameCommit")!.run();
      assert((await send({ type: "blameCommits" })).commits.length === 1, "hidden blame remained actionable");
    } finally {
      window.lithe.detachSurface("blame-split"); container.remove();
      await window.lithe.retain([]);
    }
  });
  await check("Git gutter decorations preserve text and reject stale actions", async () => {
    const text = "added\nmodified\ndeleted";
    await send({ type: "open", text });
    await window.lithe.activate({ id: "git-gutter", text, revision: 0, language: "plaintext", readonly: false });
    const model = editor.getModel()!;
    try {
      await window.lithe.gitState("git-gutter", { revision: 0, markers: ["added", "modified", "deleted"].map((kind, index) => ({
        id: `marker-${index}`, line: index + 1, kind, stage: true, unstage: false, discard: true,
      })) });
      const markers = model.getAllDecorations().filter(value => value.options.linesDecorationsClassName?.includes("lithe-git-marker"));
      assert(markers.length === 3, "Git change kinds were not rendered in the line decoration gutter");
      assert(markers.every(value => !value.options.glyphMarginClassName), "Git markers occupied the breakpoint lane");
      assert(model.getValue() === text && !model.canUndo(), "Git presentation changed document text or undo history");
      editor.setPosition({ lineNumber: 2, column: 1 });
      for (const action of ["show", "stage", "discard"]) await editor.getAction(`lithe.git.${action}`)!.run();
      const before = await send({ type: "gitLineActions" });
      assert(before.actions.join("|") === "show|stage|discard", "Git gutter actions did not reach the host");
      editor.executeEdits("integration", [{ range: new Range(1, 1, 1, 1), text: "new\n" }]);
      await window.lithe.gitState("git-gutter", { revision: 0, markers: [] });
      assert(model.getAllDecorations().filter(value => value.options.linesDecorationsClassName?.includes("lithe-git-marker")).length === 3,
        "old native snapshot replaced decorations while an edit was awaiting acknowledgement");
      await editor.getAction("lithe.git.show")!.run();
      const after = await send({ type: "gitLineActions" });
      assert(after.actions.length === before.actions.length, "outdated Git marker remained actionable after input");
      const snapshot = await window.lithe.freeze("git-gutter");
      window.lithe.unlock("git-gutter");
      await window.lithe.gitState("git-gutter", { revision: snapshot.revision, markers: [] });
      assert(!model.getAllDecorations().some(value => value.options.linesDecorationsClassName?.includes("lithe-git-marker")), "Git refresh left old gutter marks");
    } finally { await window.lithe.retain([]); }
  });
  await check("CodeVision lenses route actions and reject stale document versions", async () => {
    const text = "class Vision {}";
    await send({ type: "open", text });
    await window.lithe.activate({ id: "vision", text, revision: 0, language: "java", readonly: false });
    const model = editor.getModel()!;
    const provider = StandaloneServices.get(ILanguageFeaturesService).codeLensProvider.ordered(model)[0];
    const lenses = await provider.provideCodeLenses(model, CancellationToken.None);
    try {
      assert(lenses?.lenses.length === 3, "CodeVision lost usages, implementations or author");
      assert(lenses!.lenses.map(lens => lens.command?.title).join("|") === "2 usages|1 implementation|Fixture Author", "CodeVision labels changed");
      const commands = StandaloneServices.get(ICommandService);
      for (const lens of lenses!.lenses) await commands.executeCommand(lens.command!.id, ...lens.command!.arguments!);
      const before = await send({ type: "codeVisionActions" });
      assert(before.actions.join("|") === "usages|implementations|author", "CodeVision command used the wrong action");
      editor.executeEdits("integration", [{ range: new Range(1, 1, 1, 1), text: "// new\n" }]);
      const stale = lenses!.lenses[0].command!;
      await commands.executeCommand(stale.id, ...stale.arguments!);
      const after = await send({ type: "codeVisionActions" });
      assert(after.actions.length === before.actions.length, "old CodeVision navigated after an edit");
      await window.lithe.retain([]);
      await commands.executeCommand(stale.id, ...stale.arguments!);
      const closed = await send({ type: "codeVisionActions" });
      assert(closed.actions.length === before.actions.length, "closed CodeVision retained an actionable model");
    } finally { lenses?.dispose(); await window.lithe.retain([]); }
  });
  await check("non-Java models use host hover completion and formatting providers", async () => {
    const services = StandaloneServices.get(ILanguageFeaturesService);
    for (const language of ["python", "rust", "xml"]) {
      const id = `host-${language}`;
      const text = "class Probe {}";
      await send({ type: "open", text });
      await window.lithe.activate({ id, text, revision: 0, language, readonly: false });
      const model = editor.getModel()!;
      try {
        const hoverProvider = services.hoverProvider.ordered(model)[0];
        assert(hoverProvider, `missing ${language} hover provider`);
        const hover = await hoverProvider.provideHover(model, { lineNumber: 1, column: 1 }, CancellationToken.None, { verbosityRequest: undefined });
        assert(hover?.contents[0]?.value === "Host hover", `host hover missing for ${language}`);
        const provider = services.completionProvider.ordered(model).find(provider => provider.triggerCharacters?.includes("."));
        assert(provider, `missing ${language} completion provider`);
        const result = await provider.provideCompletionItems(model, { lineNumber: 1, column: 1 },
          { triggerKind: languages.CompletionTriggerKind.Invoke }, CancellationToken.None);
        assert(result?.suggestions[0]?.kind === languages.CompletionItemKind.Method, "LSP method kind was lost");
        assert(result?.suggestions[0]?.insertTextRules === languages.CompletionItemInsertTextRule.InsertAsSnippet, "snippet format was lost");
        assert(result?.suggestions[0]?.sortText === "001" && result?.suggestions[0]?.filterText === "sample", "completion ranking was lost");
        const resolved = await provider.resolveCompletionItem!(result!.suggestions[0], CancellationToken.None);
        assert(resolved?.documentation === "Resolved documentation", "completion resolve did not reach the host");
        assert(resolved?.additionalTextEdits?.[0]?.text === "import sample\n", "resolved import edit was lost");
        assert(resolved?.insertTextRules === languages.CompletionItemInsertTextRule.InsertAsSnippet, "resolve lost snippet mode");
        const formatter = services.documentFormattingEditProvider.ordered(model)[0];
        assert(formatter, `missing ${language} formatting provider`);
        const edits = await formatter.provideDocumentFormattingEdits(model, { tabSize: 4, insertSpaces: true }, CancellationToken.None);
        assert(edits?.length, `host formatting missing for ${language}`);
      } finally { await window.lithe.retain([]); }
    }
  });
  await check("accepted completion expands snippets imports and tab stops in one undo", async () => {
    const text = "// header\nsample", id = "snippet-accept";
    await send({ type: "open", text });
    await window.lithe.activate({ id, text, revision: 0, language: "python", readonly: false });
    const model = editor.getModel()!;
    const position = new Position(2, 7);
    editor.setPosition(position);
    const provider = StandaloneServices.get(ILanguageFeaturesService).completionProvider.ordered(model)
      .find(provider => provider.triggerCharacters?.includes("."))!;
    const list = await provider.provideCompletionItems(model, position,
      { triggerKind: languages.CompletionTriggerKind.Invoke }, CancellationToken.None);
    try {
      // Exercise the pinned Monaco acceptance path with a real host-resolved item;
      // the suggestion popup's animation is not a synchronization dependency.
      const item = new CompletionItem(position, list!.suggestions[0], list!, provider);
      await item.resolve(CancellationToken.None);
      const controller = SuggestController.get(editor)!;
      (controller as any)._insertSuggestion({ item, index: 0, model: { clipboardText: undefined, items: [item] } }, 0);
      assert(model.getValue() === "import sample\n// header\nsampleMethod(value)", "accepted snippet/import content was incorrect");
      assert(model.getValueInRange(editor.getSelection()!) === "value", "first snippet placeholder was not selected");
      editor.trigger("integration", "jumpToNextSnippetPlaceholder", {});
      assert(editor.getSelection()!.isEmpty() && editor.getPosition()!.column === 20,
        "Tab did not reach the final snippet stop");
      await model.undo();
      assert(model.getValue() === text, "snippet and import were not undone together");
      await window.lithe.freeze(id);
    } finally {
      list?.dispose?.();
      await window.lithe.retain([]);
    }
  });
  await check("completion resolve rejects edits replacement lists cancellation and closed models", async () => {
    const services = StandaloneServices.get(ILanguageFeaturesService);
    for (const change of ["edit", "replace", "cancel", "close", "rename", "rename-back"]) {
      const id = `resolve-${change}`, text = "sample";
      await send({ type: "open", text });
      await window.lithe.activate({ id, text, revision: 0, language: "python", readonly: false });
      const model = editor.getModel()!;
      const provider = services.completionProvider.ordered(model).find(provider => provider.triggerCharacters?.includes("."))!;
      const request = () => provider.provideCompletionItems(model, { lineNumber: 1, column: 7 },
        { triggerKind: languages.CompletionTriggerKind.Invoke }, CancellationToken.None);
      const list = await request();
      const item = list!.suggestions[0];
      const cancellation = new CancellationTokenSource();
      await send({ type: "holdResolve" });
      const pending = Promise.resolve(provider.resolveCompletionItem!(item, cancellation.token));
      try {
        await send({ type: "awaitResolve" });
        if (change === "edit") editor.executeEdits("integration", [{ range: new Range(1, 7, 1, 7), text: "New" }]);
        if (change === "replace") await request();
        if (change === "cancel") cancellation.cancel();
        if (change === "rename" || change === "rename-back") {
          await window.lithe.updateDocument({ id, filename: "Other.py", locationRevision: 1, readonly: false });
          if (change === "rename-back")
            await window.lithe.updateDocument({ id, filename: "Original.py", locationRevision: 2, readonly: false });
        }
        if (change === "close") await window.lithe.retain([]);
        await send({ type: "releaseResolve" });
        const resolved = await pending;
        assert(!resolved?.additionalTextEdits?.length && !resolved?.documentation,
          `stale resolve survived ${change}`);
      } finally {
        await send({ type: "releaseResolve" });
        await pending;
        cancellation.dispose();
        list?.dispose?.();
        if (!model.isDisposed()) await window.lithe.freeze(id);
        await window.lithe.retain([]);
      }
    }
  });
  await check("rename prepares unopened targets and applies undoable versioned workspace edits", async () => {
    const text = "let value = 1", other = "print(value)";
    await send({ type: "open", id: "rename-source", text });
    await send({ type: "open", id: "rename-target", text: other });
    await window.lithe.activate({ id: "rename-source", text, revision: 0, language: "python", readonly: false });
    const source = editor.getModel()!;
    try {
      const provider = StandaloneServices.get(ILanguageFeaturesService).renameProvider.ordered(source)[0];
      assert(provider, "Monaco rename provider is missing");
      const result = await provider.provideRenameEdits(source, new Position(1, 6), "renamed", CancellationToken.None);
      assert(result?.edits.length === 2 && !result.rejectReason, "rename lost a workspace target");
      const bulk = StandaloneServices.get(IBulkEditService);
      await bulk.apply(result!);
      await window.lithe.freeze("rename-source");
      await window.lithe.freeze("rename-target");
      const nativeSource = await send({ type: "fixtureSnapshot", id: "rename-source" });
      const nativeTarget = await send({ type: "fixtureSnapshot", id: "rename-target" });
      assert(nativeSource.text === "let renamed = 1" && nativeTarget.text === "print(renamed)",
        "workspace edits failed to synchronize to both native documents");
      window.lithe.unlock("rename-source");
      window.lithe.unlock("rename-target");
      const target = monacoEditor.getModel((result!.edits[1] as languages.IWorkspaceTextEdit).resource)!;
      await source.undo();
      await target.undo();
      assert(source.getValue() === text && target.getValue() === other, "rename discarded a model's undo history");
      let rejected = false;
      try { await bulk.apply(result!); } catch { rejected = true; }
      assert(rejected && source.getValue() === text && target.getValue() === other,
        "stale workspace edit partially modified the models");
    } finally {
      await window.lithe.freeze("rename-source");
      await window.lithe.freeze("rename-target");
      await window.lithe.retain([]);
    }
  });
  await check("quick fixes resolve lazily sync workspace edits before commands and reject stale actions", async () => {
    const text = "let value = 1", other = "print(value)";
    await send({ type: "open", id: "rename-source", text });
    await send({ type: "open", id: "rename-target", text: other });
    await window.lithe.activate({ id: "rename-source", text, revision: 0, language: "python", readonly: false });
    const model = editor.getModel()!;
    let actions: languages.CodeActionList | undefined;
    try {
      const provider = StandaloneServices.get(ILanguageFeaturesService).codeActionProvider.ordered(model)[0];
      actions = (await provider.provideCodeActions(model, new Range(1, 5, 1, 10),
        { markers: [], trigger: languages.CodeActionTriggerType.Invoke, only: "quickfix" }, CancellationToken.None)) ?? undefined;
      const action = actions!.actions[0];
      assert(action.kind === "quickfix" && action.isPreferred, "quick-fix metadata was lost");
      const initial = await send({ type: "fixtureSnapshot", id: "rename-source" });
      const command = action.command!;
      await StandaloneServices.get(ICommandService).executeCommand(command.id, ...command.arguments!);
      const applied = await send({ type: "fixtureSnapshot", id: "rename-source" });
      assert(applied.text === "let fixed = 1" && applied.commandCount === initial.commandCount + 1,
        "code action did not execute after synchronizing edits");
      await StandaloneServices.get(ICommandService).executeCommand(command.id, ...command.arguments!);
      const repeated = await send({ type: "fixtureSnapshot", id: "rename-source" });
      assert(repeated.commandCount === applied.commandCount, "stale action executed its command again");
      await model.undo();
      assert(model.getValue() === text, "code action bypassed Monaco undo");
    } finally {
      actions?.dispose();
      await window.lithe.freeze("rename-source");
      // The target is loaded by the action; retain releases both cached models.
      await window.lithe.retain([]);
    }
  });
  await check("Markdown split scroll synchronizes without echo or document edits", async () => {
    const id = "markdown-scroll", text = "# Heading\nparagraph\n".repeat(300);
    await window.lithe.activate({ id, text, revision: 0, filename: "README.md", readonly: false });
    const model = editor.getModel()!, version = model.getVersionId();
    try {
      // automaticLayout observes the real host container. A synthetic height
      // races that observation and changes the denominator after scrolling.
      editor.layout();
      const before = (await send({ type: "markdownScrollRequests" })).requests.length;
      await window.lithe.markdownScroll({ id, ratio: 0.6 });
      // Deterministically reproduce a late CodeLens/view-zone height change.
      // WebKit previously failed here when a preceding document's lens vanished.
      let zone = "";
      editor.changeViewZones(accessor => { zone = accessor.addZone({ afterLineNumber: 1,
        heightInLines: 3, domNode: document.createElement("div") }); });
      const expandedExtent = editor.getScrollHeight() - editor.getLayoutInfo().height;
      assert(Math.abs(editor.getScrollTop() / expandedExtent - 0.6) < 0.001,
        "late view-zone height change lost the preview scroll position");
      editor.changeViewZones(accessor => accessor.removeZone(zone));
      editor.layout(); // Re-measuring the actual viewport must preserve the ratio.
      const extent = Math.max(0, editor.getScrollHeight() - editor.getLayoutInfo().height);
      assert(Math.abs(editor.getScrollTop() / extent - 0.6) < 0.001,
        `preview scroll did not move the source editor (scroll=${editor.getScrollTop()}, extent=${extent})`);
      assert((await send({ type: "markdownScrollRequests" })).requests.length === before,
        "preview scroll echoed back as an editor gesture");
      editor.setScrollTop(extent * 0.25, monacoEditor.ScrollType.Immediate);
      const result = await send({ type: "awaitMarkdownScroll", after: before });
      const request = result.requests[result.requests.length - 1];
      assert(request.id === id && Math.abs(request.ratio - 0.25) < 0.001,
        "source scroll used a different document or wrong range");
      editor.setScrollTop(extent * 0.3, monacoEditor.ScrollType.Immediate);
      await window.lithe.markdownScroll(null); // Cancels the queued old-document report.
      assert(model.getVersionId() === version && model.getValue() === text, "scroll synchronization mutated source or undo");
    } finally { await window.lithe.markdownScroll(null); await window.lithe.retain([]); }
  });
  await check("definition navigation drains edits and routes the owning split document", async () => {
    const id = "definition-source", text = "class Probe {}";
    await send({ type: "open", id, text });
    await window.lithe.activate({ id, text, revision: 0, filename: "Probe.java", readonly: false });
    await window.lithe.showSecondary({ id, readonly: false });
    const secondary = monacoEditor.getEditors().find(view => view !== editor && view.getModel() === editor.getModel())!;
    try {
      const before = (await send({ type: "definitionRequests" })).requests.length;
      secondary.executeEdits("navigation", [{ range: new Range(1, 7, 1, 7), text: "New" }]);
      secondary.setPosition({ lineNumber: 1, column: 10 });
      const action = secondary.getAction("lithe.goToDefinition")!;
      await action.run();
      const requests = (await send({ type: "definitionRequests" })).requests;
      assert(requests.length === before + 1, "definition action was not dispatched");
      const request = requests[requests.length - 1];
      const native = await send({ type: "fixtureSnapshot", id });
      assert(request.id === id && request.line === 0 && request.column === 9 && request.revision === native.revision,
        "navigation used another view's caret or an undrained document revision");
      await window.lithe.holdForClose(id, "definition-close");
      await action.run();
      assert((await send({ type: "definitionRequests" })).requests.length === requests.length,
        "definition escaped a close hold");
    } finally {
      await window.lithe.releaseClose("definition-close");
      await window.lithe.freeze(id);
      window.lithe.hideSecondary();
      await window.lithe.retain([]);
    }
  });
  await check("debug markers distinguish breakpoint state and clear without changing document history", async () => {
    const id = "debug-markers", text = "first\nsecond\nthird";
    await send({ type: "open", text });
    await window.lithe.activate({ id, text, revision: 0, language: "plaintext", readonly: false });
    const model = editor.getModel()!, version = model.getVersionId();
    try {
      await window.lithe.debugState(id, { muted: false, paused: true, executionLine: 2, canRunToCursor: true,
        variables: [{ name: "second", value: "<value>\n42" }, { name: "sec", value: "wrong substring" }], breakpoints: [
        { line: 1, enabled: false, verified: true, logpoint: false },
        { line: 2, enabled: true, verified: false, logpoint: true, message: "Pending adapter" },
        { line: 3, enabled: true, verified: true, logpoint: false, conditional: true },
      ] });
      const decorations = model.getAllDecorations();
      assert(decorations.some(item => item.options.glyphMarginClassName?.includes("debug-breakpoint-disabled")),
        "disabled breakpoint state was lost");
      assert(decorations.some(item => item.options.glyphMarginClassName?.includes("debug-breakpoint-log-unverified")),
        "unverified logpoint state was lost");
      assert(decorations.some(item => item.range.startLineNumber === 2 && item.options.className === "lithe-execution-line"),
        "execution line decoration was missing");
      assert(decorations.some(item => item.options.glyphMarginClassName?.includes("debug-breakpoint-conditional")),
        "conditional breakpoint icon was lost");
      assert(decorations.some(item => item.options.after?.content === "  second = <value> 42"),
        "inline variables lost literal text, normalization, or identifier boundaries");
      const hoverProvider = StandaloneServices.get(ILanguageFeaturesService).hoverProvider.ordered(model)[0];
      const hover = await hoverProvider.provideHover(model, new Position(2, 2), CancellationToken.None);
      assert(hover?.contents.length === 2 && hover.contents[0].value.includes("\\<value\\>") &&
        hover.contents[1].value === "Host hover", "debug hover lost literal values or language documentation");
      editor.setPosition({ lineNumber: 3, column: 2 });
      const runAction = editor.getAction("lithe.runToCursor")!;
      assert(runAction.isSupported(), "paused session did not enable Run to Cursor");
      await runAction.run();
      const requests = (await send({ type: "debugRequests" })).requests;
      assert(requests.at(-1).id === id && requests.at(-1).line === 3 && requests.at(-1).column === 2,
        "Run to Cursor lost its source document or caret location");
      await window.lithe.holdForClose(id, "debug-close");
      await runAction.run();
      assert((await send({ type: "debugRequests" })).requests.length === requests.length,
        "Run to Cursor escaped a document close hold");
      await window.lithe.releaseClose("debug-close");
      await window.lithe.debugState(id, { muted: false, executionLine: 2, revision: -1,
        variables: [{ name: "second", value: "stale" }], breakpoints: [] });
      assert(!model.getAllDecorations().some(item => item.options.after?.inlineClassName === "lithe-debug-value"),
        "old source revision displayed a stale variable value");
      await window.lithe.debugState(id, { muted: false, breakpoints: [] });
      assert(!runAction.isSupported(), "resumed session retained Run to Cursor");
      assert(!model.getAllDecorations().some(item => item.options.glyphMarginClassName?.includes("lithe-")),
        "ended debug session retained markers");
      assert(!model.getAllDecorations().some(item => item.options.after?.inlineClassName === "lithe-debug-value"),
        "ended debug session retained variable values");
      assert(model.getVersionId() === version && model.getValue() === text, "debug decorations mutated document history");
    } finally { await window.lithe.retain([]); }
  });
  await check("editor commands preserve multi-selection undo and read-only ownership", async () => {
    const container = document.createElement("div");
    container.style.cssText = "height:400px;width:800px";
    document.body.append(container);
    const model = monacoEditor.createModel("alpha\nbeta\ngamma\ndelta", "plaintext");
    const view = monacoEditor.create(container, { model });
    try {
      view.setSelections([new Selection(1, 1, 2, 1), new Selection(3, 1, 4, 1)]);
      await runEditorCommand(view, { type: "copyLineDown" }, true);
      assert(model.getValue() === "alpha\nalpha\nbeta\ngamma\ngamma\ndelta", "line command lost multiple selections");
      await model.undo();
      assert(model.getValue() === "alpha\nbeta\ngamma\ndelta", "line command did not undo atomically");
      await runEditorCommand(view, { type: "deleteLine" }, false);
      assert(model.getValue() === "alpha\nbeta\ngamma\ndelta", "host read-only policy allowed a menu edit");
      view.setPosition({ lineNumber: 1, column: 3 });
      await runEditorCommand(view, { type: "expandSelection" }, false);
      assert(model.getValueInRange(view.getSelection()!) === "alpha", "smart selection did not expand to word");
      await runEditorCommand(view, { type: "shrinkSelection" }, false);
      assert(view.getSelection()!.isEmpty(), "smart selection did not restore caret");
    } finally { view.dispose(); model.dispose(); container.remove(); }
  });
  await check("editor bracket and fold commands operate on their owning view", async () => {
    const language = "plaintext";
    const configuration = languages.setLanguageConfiguration(language, { brackets: [["{", "}"]], comments: { lineComment: "//" } });
    const folding = languages.registerFoldingRangeProvider(language, {
      provideFoldingRanges: () => [{ start: 1, end: 4 }, { start: 2, end: 3 }],
    });
    const container = document.createElement("div");
    container.style.cssText = "height:400px;width:800px";
    document.body.append(container);
    const model = monacoEditor.createModel("{\n  {\n    value\n  }\n}", language);
    const view = monacoEditor.create(container, { model, folding: true });
    try {
      view.setPosition({ lineNumber: 1, column: 1 });
      await runEditorCommand(view, { type: "goToMatchingBracket" }, false);
      assert(view.getPosition()!.lineNumber === 5, "bracket jump missed matching brace");
      await runEditorCommand(view, { type: "selectToBracket", selectBrackets: false }, false);
      assert(!model.getValueInRange(view.getSelection()!).includes("}\n}"), "bracket selection ignored interior option");
      view.setPosition({ lineNumber: 3, column: 5 });
      await runEditorCommand(view, { type: "toggleComment" }, true);
      assert(model.getLineContent(3).includes("//"), "comment command ignored language configuration");
      await model.undo();
      await runEditorCommand(view, { type: "foldAll" }, false);
      const foldedTop = view.getTopForLineNumber(5);
      await runEditorCommand(view, { type: "unfoldAll" }, false);
      const expandedTop = view.getTopForLineNumber(5);
      assert(expandedTop > foldedTop, "fold/unfold menu commands did not change visible lines");
      await runEditorCommand(view, { type: "foldLevel", level: 2 }, false);
      const levelTop = view.getTopForLineNumber(5);
      assert(levelTop > foldedTop && levelTop < expandedTop, "level folding did not collapse only the nested region");
    } finally { view.dispose(); model.dispose(); container.remove(); folding.dispose(); configuration.dispose(); }
  });
  await check("Monaco find widget replaces regex captures and retains input focus", async () => {
    const container = document.createElement("div");
    container.style.cssText = "height:400px;width:800px";
    document.body.append(container);
    const model = monacoEditor.createModel("alpha 1\nalpha 2\nALPHA 3", "plaintext");
    const view = monacoEditor.create(container, { model });
    try {
      await runEditorCommand(view, { type: "find", replace: true }, true);
      const controller = view.getContribution("editor.contrib.findController") as any;
      const state = controller.getState();
      assert(state.isRevealed && state.isReplaceRevealed, "replace command did not open Monaco widget");
      assert(document.activeElement?.closest(".find-widget"), "find command lost input focus");
      state.change({ searchString: "alpha (\\d)", replaceString: "$1 alpha", isRegex: true, matchCase: true }, true);
      assert(state.matchesCount === 2 && view.getSelection()!.endColumn === 8, "widget search did not locate while typing");
      controller.replaceAll();
      assert(model.getValue() === "1 alpha\n2 alpha\nALPHA 3", "widget replacement ignored regex captures");
      await model.undo();
      assert(model.getValue() === "alpha 1\nalpha 2\nALPHA 3", "widget replacement did not undo atomically");
    } finally { view.dispose(); model.dispose(); container.remove(); }
  });
  await check("native find bar jumps while typing and replaces through Monaco undo", async () => {
    const id = "native-find", text = "public alpha\npublic beta\nPUBLIC gamma";
    await send({ type: "open", id, text });
    await window.lithe.activate({ id, text, revision: 0, language: "plaintext", readonly: false });
    const model = editor.getModel()!;
    const input = { id, token: "query-1", visible: true, query: "pub", matchCase: false, wholeWord: false, regex: false };
    try {
      editor.setPosition({ lineNumber: 1, column: 1 });
      const result = await window.lithe.nativeFind(input);
      assert(result.count === 3 && result.index === 0, "native bar did not convert Monaco's match position to a host index");
      assert(editor.getSelection()?.endColumn === 4, "typing did not immediately select the first match");
      const widget = (editor.getContribution("editor.contrib.findController") as any).getState();
      assert(!widget.isRevealed, "native bar unexpectedly opened a second find widget");
      await window.lithe.nativeFind({ ...input, command: "next" });
      assert(editor.getSelection()?.startLineNumber === 2, "next did not jump to the next match");
      assert((await window.lithe.nativeFind({ ...input, command: "next" })).index === 2, "next reported the wrong zero-based match index");
      assert((await window.lithe.nativeFind({ ...input, command: "next" })).index === 0, "next did not wrap to the first match");
      await window.lithe.nativeFind({ ...input, command: "previous" });
      assert(editor.getSelection()?.startLineNumber === 3, "previous did not wrap to the last match");
      const exact = { ...input, token: "query-2", query: "public", matchCase: true, wholeWord: true };
      assert((await window.lithe.nativeFind(exact)).count === 2, "case/whole-word options ignored");
      await window.lithe.nativeFind({ ...exact, command: "replace", replacement: "private" });
      assert(model.getValue() === "private alpha\npublic beta\nPUBLIC gamma", "replace-next did not replace the selected match");
      await model.undo();
      await window.lithe.nativeFind({ ...exact, command: "replaceAll", replacement: "private" });
      assert(model.getValue() === "private alpha\nprivate beta\nPUBLIC gamma", "native replace-all targeted wrong matches");
      await model.undo();
      assert(model.getValue() === text, "replace-all was not one undoable edit");
      const single = await window.lithe.nativeFind({ ...input, token: "query-single", query: "gamma", matchCase: true });
      assert(single.count === 1 && single.index === 0, "single native match did not use a zero-based index");
      const regex = { ...input, token: "query-3", query: "public (\\w+)", regex: true, matchCase: true };
      editor.setPosition({ lineNumber: 1, column: 1 });
      await window.lithe.nativeFind(regex);
      await window.lithe.nativeFind({ ...regex, command: "replaceAll", replacement: "$1 public" });
      assert(model.getValue() === "alpha public\nbeta public\nPUBLIC gamma", "regex replacement lost capture groups");
      await model.undo();
      const none = await window.lithe.nativeFind({ ...regex, query: "[" });
      assert(none.count === 0 && none.index === 0, "invalid regex retained old matches or index");
      await window.lithe.nativeFind({ ...input, visible: false });
      const snapshot = await window.lithe.freeze(id);
      assert(snapshot.text === text, "replace undo was not synchronized to the native document");
    } finally { await window.lithe.nativeFind({ ...input, visible: false }); await window.lithe.freeze(id); await window.lithe.retain([]); }
  });
  await check("native find isolates split targets and rejects closing or stale commands", async () => {
    const id = "native-find-left", right = "native-find-right", text = "public one public two";
    await send({ type: "open", id, text });
    await send({ type: "open", id: right, text });
    await window.lithe.activate({ id, text, revision: 0, language: "plaintext", readonly: false });
    await window.lithe.showSecondary({ id: right, text, revision: 0, language: "plaintext", readonly: true });
    const leftModel = editor.getModel()!;
    const secondary = monacoEditor.getEditors().find(view => view !== editor && view.getModel() !== leftModel)!;
    const input = { id: right, token: "split", visible: true, query: "public", matchCase: true, wholeWord: false, regex: false };
    try {
      await window.lithe.nativeFind(input);
      assert(secondary.getSelection()?.endColumn === 7, "native search did not target the explicit secondary document");
      secondary.blur();
      assert(!secondary.hasTextFocus(), "split editor did not release focus to the native find bar simulation");
      await window.lithe.nativeFind({ ...input, visible: false });
      assert(await window.lithe.dismissNativeFind(right), "closing native find did not restore the owning split focus");
      assert(secondary.hasTextFocus(), "native find restored focus to the wrong split");
      await window.lithe.nativeFind(input);
      await window.lithe.nativeFind({ ...input, command: "replaceAll", replacement: "bad" });
      assert(secondary.getModel()?.getValue() === text && leftModel.getValue() === text, "readonly replacement changed a document");
      await window.lithe.holdForClose(id, "native-find-close");
      await window.lithe.nativeFind({ ...input, id, command: "replaceAll", replacement: "bad" });
      assert(leftModel.getValue() === text, "find replacement bypassed close hold");
      window.lithe.releaseClose("native-find-close");
      await Promise.all([
        window.lithe.nativeFind({ ...input, id, query: "one", token: "old" }),
        window.lithe.nativeFind({ ...input, id, query: "two", token: "latest" }),
      ]);
      assert(leftModel.getValueInRange(editor.getSelection()!) === "two", "older native query won activation race");
      const staleReplacement = window.lithe.nativeFind({ ...input, id, command: "replaceAll", replacement: "bad" });
      editor.executeEdits("concurrent-input", [{ range: new Range(1, 1, 1, 1), text: "X" }]);
      await staleReplacement;
      assert(leftModel.getValue() === "X" + text, "queued replacement survived a newer edit");
      await leftModel.undo();
      await window.lithe.nativeFind({ ...input, id: "closed", command: "replaceAll", replacement: "bad" });
      assert(leftModel.getValue() === text, "missing document fell back to active editor");
    } finally {
      window.lithe.releaseClose("native-find-close");
      await window.lithe.nativeFind({ ...input, visible: false });
      await window.lithe.hideSecondary(); await window.lithe.freeze(id); await window.lithe.retain([]);
    }
  });
  await check("find matches track ordinary and multiline regex edits", async () => {
    for (const scenario of [
      { id: "find-shift", text: "alpha beta alpha", query: "alpha", regex: false,
        line: 1, column: 1, expected: [1, 12] },
      { id: "find-multiline", text: "alpha\nbeta gamma", query: "a\\nb", regex: true,
        line: 2, column: 3, expected: [4] },
    ]) {
      await send({ type: "open", id: scenario.id, text: scenario.text });
      await window.lithe.activate({ id: scenario.id, text: scenario.text, revision: 0, language: "plaintext", readonly: false });
      const model = editor.getModel()!;
      try {
        await window.lithe.find({ id: scenario.id, query: scenario.query, regex: scenario.regex });
        editor.executeEdits("find-regression", [{ range: new Range(scenario.line, scenario.column, scenario.line, scenario.column), text: "X" }]);
        const matches = model.findMatches(scenario.query, false, scenario.regex, true, null, false);
        const offsets = matches.map(match => model.getOffsetAt(match.range.getStartPosition()));
        assert(JSON.stringify(offsets) === JSON.stringify(scenario.expected), "find lost or misplaced matches after an edit");
        const state = (editor.getContribution("editor.contrib.findController") as any).getState();
        let queryChanges = 0;
        const subscription = state.onFindReplaceStateChange((change: any) => { if (change.searchString) queryChanges++; });
        try {
          await window.lithe.find({ id: scenario.id, query: scenario.query, regex: scenario.regex });
          assert(queryChanges === 0, "unchanged search query was republished");
        } finally { subscription.dispose(); }
        await model.undo();
        const snapshot = await window.lithe.freeze(scenario.id);
        assert(snapshot.text === scenario.text, "search edit undo did not restore native text");
      } finally { await window.lithe.freeze(scenario.id); await window.lithe.retain([]); }
    }
  });
  await check("line comments follow renamed filenames and remain undoable", async () => {
    const id = "line-comments", text = "value = 1";
    await send({ type: "open", id, text });
    let revision = 0;
    try {
      for (const [filename, prefix] of [["Probe.swift", "//"], ["Probe.py", "#"], [".env", "#"]]) {
        await window.lithe.activate({ id, text, revision, filename, readonly: false });
        const model = editor.getModel()!;
        editor.setPosition({ lineNumber: 1, column: 1 });
        const action = editor.getAction("editor.action.commentLine");
        assert(action, "Monaco line comment action is unavailable");
        await action!.run();
        assert(model.getValue().startsWith(prefix), `wrong comment token after rename to ${filename}`);
        await model.undo();
        assert(model.getValue() === text, "line comment did not preserve undo");
        const snapshot = await window.lithe.freeze(id);
        assert(snapshot.text === text, "comment undo did not restore native source");
        revision = snapshot.revision;
        window.lithe.unlock(id);
      }
    } finally { await window.lithe.freeze(id); await window.lithe.retain([]); }
  });
  await check("inline parameter hints preserve positions tooltip padding and accepted edits", async () => {
    const id = "inlay", text = "call(42)";
    await send({ type: "open", text });
    await window.lithe.activate({ id, text, revision: 0, language: "python", readonly: false });
    const model = editor.getModel()!;
    let result: languages.InlayHintList | undefined;
    try {
      const provider = StandaloneServices.get(ILanguageFeaturesService).inlayHintsProvider.ordered(model)[0];
      result = (await provider.provideInlayHints(model, model.getFullModelRange(), CancellationToken.None)) ?? undefined;
      const hint = result!.hints[0];
      assert(hint.position.column === 5 && hint.kind === languages.InlayHintKind.Parameter, "hint position/kind was lost");
      assert(hint.label === "value:" && hint.paddingRight, "hint presentation was lost");
      assert(typeof hint.tooltip === "object" && hint.tooltip.isTrusted === false, "hint tooltip enabled trusted commands");
      assert(hint.textEdits?.[0]?.text === "value: ", "hint acceptance edit was lost");
      assert(model.getValue() === text, "displaying hints mutated source text");
    } finally { result?.dispose(); await window.lithe.retain([]); }
  });
  await check("concurrent first close holds share one edit stream and release the model", async () => {
    const id = "concurrent-close", text = "first\r\nlast";
    const payload = { id, text, revision: 0, language: "plaintext", readonly: false };
    await send({ type: "open", id, text });
    let model: ReturnType<typeof editor.getModel>;
    try {
      // Both closes reach the same tokenizer await before the model exists.
      // An ordinary activation may join them, but must not create another owner.
      const [first, second] = await Promise.all([
        window.lithe.holdForClose(id, "first-close", payload),
        window.lithe.holdForClose(id, "second-close", payload),
        window.lithe.activate(payload),
      ]);
      model = editor.getModel()!;
      assert(first.text === text && second.text === text, "concurrent closes did not share the initial text");
      window.lithe.releaseClose("first-close");
      assert(editor.getOption(monacoEditor.EditorOption.readOnly), "one close released another owner's lock");
      window.lithe.releaseClose("second-close");
      assert(!editor.getOption(monacoEditor.EditorOption.readOnly), "cancelled closes left the document locked");
      editor.executeEdits("integration", [{ range: new Range(2, 5, 2, 5), text: "!" }]);
      const snapshot = await window.lithe.freeze(id);
      const native = await send({ type: "fixtureSnapshot", id });
      assert(snapshot.revision === 1 && native.revision === 1, "one input emitted multiple native edits");
      assert(snapshot.text === "first\r\nlast!" && native.text === snapshot.text, "concurrent initialization broke source synchronization");
      window.lithe.unlock(id);
      await model.undo();
      const undone = await window.lithe.freeze(id);
      assert(undone.text === text && undone.revision === 2, "shared initialization lost undo or duplicated its edit");
    } finally {
      window.lithe.releaseClose("first-close"); window.lithe.releaseClose("second-close");
      await window.lithe.retain([]);
    }
    assert(model!.isDisposed(), "concurrent initialization leaked a model reference");
  });
  await check("closing holds survive ordinary save unlock and release independently", async () => {
    const id = "closing-hold", text = "unsaved";
    await send({ type: "open", text });
    await window.lithe.activate({ id, text, revision: 0, language: "plaintext", readonly: false });
    try {
      const snapshot = await window.lithe.holdForClose(id, "window-close");
      await window.lithe.holdForClose(id, "app-close");
      assert(snapshot.text === text && editor.getOption(monacoEditor.EditorOption.readOnly), "close did not freeze input");
      await window.lithe.freeze(id);
      window.lithe.unlock(id);
      assert(editor.getOption(monacoEditor.EditorOption.readOnly), "save unlocked an active close confirmation");
      window.lithe.releaseClose("window-close");
      window.lithe.releaseClose("window-close");
      assert(editor.getOption(monacoEditor.EditorOption.readOnly), "duplicate release unlocked another owner");
      window.lithe.releaseClose("app-close");
      assert(!editor.getOption(monacoEditor.EditorOption.readOnly), "cancelled close left editing disabled");
    } finally {
      window.lithe.releaseClose("window-close");
      window.lithe.releaseClose("app-close");
      await window.lithe.retain([]);
    }
  });
  await check("formatting uses Monaco undo and rejects results after new input", async () => {
    const text = "class Probe {}";
    await send({ type: "open", text });
    await window.lithe.activate({ id: "format", text, revision: 0, language: "java", readonly: false });
    const model = editor.getModel()!;
    const action = editor.getAction("editor.action.formatDocument");
    assert(action, "Monaco format command missing");
    await action!.run();
    assert(model.getValue() === "class Probe { }", "format edits were not applied");
    await model.undo();
    assert(model.getValue() === text, "format was not undoable");
    const snapshot = await window.lithe.freeze("format");
    await send({ type: "save", revision: snapshot.revision, expected: text });
    window.lithe.unlock("format");
    const provider = StandaloneServices.get(ILanguageFeaturesService).documentFormattingEditProvider.ordered(model)[0];
    await send({ type: "holdFormat" });
    const pending = Promise.resolve(provider.provideDocumentFormattingEdits(model, { tabSize: 4, insertSpaces: true }, CancellationToken.None));
    try {
      await send({ type: "awaitFormat" });
      editor.executeEdits("integration", [{ range: new Range(1, 12, 1, 12), text: "Updated" }]);
      await send({ type: "releaseFormat" });
      const edits = await pending;
      assert(!edits?.length, "late formatting overwrote newer input");
      assert(model.getValue().includes("Updated"), "new input was lost");
    } finally {
      await send({ type: "releaseFormat" });
      await pending;
      await window.lithe.freeze("format");
      await window.lithe.retain([]);
    }
  });
  await check("active rename preserves shared model history and rejects old formatting", async () => {
    for (const ending of ["rename", "rename-back", "close", "hold"]) {
      const id = `format-${ending}`, text = "class Probe {}";
      await send({ type: "open", id, text });
      await window.lithe.activate({ id, text, revision: 0, filename: "Probe.java", locationRevision: 0, readonly: false });
      const model = editor.getModel()!;
      const provider = StandaloneServices.get(ILanguageFeaturesService).documentFormattingEditProvider.ordered(model)[0];
      // Leave a real undo item in the shared buffer before changing its identity.
      editor.executeEdits("integration", [{ range: new Range(1, 1, 1, 1), text: "// pending\n" }]);
      const snapshot = await window.lithe.freeze(id);
      window.lithe.unlock(id);
      await send({ type: "holdFormat" });
      const pending = Promise.resolve(provider.provideDocumentFormattingEdits(model, { tabSize: 4, insertSpaces: true }, CancellationToken.None));
      try {
        await send({ type: "awaitFormat" });
        if (ending === "close") await window.lithe.retain([]);
        else if (ending === "hold") await window.lithe.holdForClose(id, "format-close");
        else {
          await window.lithe.updateDocument({ id, filename: "Probe.py", locationRevision: 1, readonly: false });
          assert(editor.getModel() === model && model.getLanguageId() === "python", "active rename did not update the existing model language");
          assert(model.getValue() === snapshot.text, "rename discarded unsaved text");
          if (ending === "rename-back")
            await window.lithe.updateDocument({ id, filename: "Probe.java", locationRevision: 2, readonly: false });
        }
        await send({ type: "releaseFormat" });
        assert(!(await pending)?.length, `old formatting survived ${ending}`);
        if (ending.startsWith("rename")) {
          await model.undo();
          assert(model.getValue() === text, "rename discarded Monaco undo history");
        }
      } finally {
        await send({ type: "releaseFormat" });
        await pending;
        await window.lithe.releaseClose("format-close");
        if (!model.isDisposed()) await window.lithe.freeze(id);
        await window.lithe.retain([]);
      }
    }
  });
  await check("TextMate worker updates multiline state after Unicode edits and releases models", async () => {
    const text = 'class Probe {\n/* 中文 😀\ncomment */ int value;\n}';
    await send({ type: "open", text });
    await window.lithe.activate({ id: "tm", text, revision: 0, language: "java", readonly: false });
    const model = editor.getModel()!;
    await window.lithe.tokenizationReady();
    // This uses the rendered model token store, not a separate grammar instance.
    const tokenType = () => (model as any).tokenization.getLineTokens(3).getStandardTokenType(0);
    assert(tokenType() === 1, "multiline comment state missing");
    editor.executeEdits("integration", [{ range: new Range(2, 1, 2, 3), text: "//" }]);
    await window.lithe.tokenizationReady();
    assert(tokenType() !== 1, "stale multiline state survived edit");
    window.lithe.configure({ dark: false, fontFamily: "monospace", fontSize: 13, wrap: false });
    await window.lithe.tokenizationReady();
    assert(!window.lithe.tokenizationStatus().failed, "theme change broke worker");
    await window.lithe.retain([]);
    assert(window.lithe.tokenizationStatus().models === 0, "worker retained closed document");
  });
  await check("semantic provider coalesces requests and rejects results after edits", async () => {
    const text = "class Probe {}";
    await send({ type: "open", text });
    await window.lithe.activate({ id: "sem", text, revision: 0, language: "java", readonly: false });
    const model = editor.getModel()!;
    const provider = StandaloneServices.get(ILanguageFeaturesService).documentSemanticTokensProvider.all(model)[0];
    const first = await provider.provideDocumentSemanticTokens(model, null, CancellationToken.None);
    assert(first?.data?.length === 5 && first.data[1] === 6, "semantic provider did not encode server legend");
    const before = await send({ type: "semanticCount" });
    await provider.provideDocumentSemanticTokens(model, null, CancellationToken.None);
    const after = await send({ type: "semanticCount" });
    assert(before.count === after.count, "unchanged model re-requested semantic tokens");
    await send({ type: "holdSemantic" });
    window.lithe.semanticRefresh();
    const pending = provider.provideDocumentSemanticTokens(model, null, CancellationToken.None);
    await send({ type: "awaitSemantic" });
    editor.executeEdits("integration", [{ range: new Range(1, 12, 1, 12), text: "Updated" }]);
    await send({ type: "releaseSemantic" });
    assert(await pending === null, "old semantic response survived text edit");
    const updated = await provider.provideDocumentSemanticTokens(model, null, CancellationToken.None);
    assert(updated?.data?.length === 5, "new revision was not re-requested");
    await window.lithe.retain([]);
  });
  await send({ type: "complete", cases, userAgent: navigator.userAgent });
}
void verify().catch(error => send({ type: "failure", message: String(error) }));
