/// <reference path="./monaco-tokenization-internals.d.ts" />
import { applyStateStackDiff } from "vscode-textmate";
import { createJavaGrammar, INITIAL, tokenizeLineWithinLimit, tokenRole } from "./textmate-grammar";
import { TokenizationRegistry, Token, TokenizationResult, EncodedTokenizationResult } from "monaco-editor/esm/vs/editor/common/languages.js";
import { ContiguousMultilineTokensBuilder } from "monaco-editor/esm/vs/editor/common/tokens/contiguousMultilineTokensBuilder.js";
import { StandaloneServices } from "monaco-editor/esm/vs/editor/standalone/browser/standaloneServices.js";
import { IStandaloneThemeService } from "monaco-editor/esm/vs/editor/standalone/common/standaloneTheme.js";
import { ILanguageService } from "monaco-editor/esm/vs/editor/common/languages/language.js";

export interface JavaTextMateResources {
  wasmURL?: string;
  grammarURL?: string;
  createWorker?: () => Worker;
}

export async function installJavaTextMate(resourcesConfig: JavaTextMateResources = {}) {
  const resources = await Promise.all([fetch(resourcesConfig.wasmURL ?? "onig.wasm"),
    fetch(resourcesConfig.grammarURL ?? "java.tmLanguage.json"),
    resourcesConfig.createWorker ? Promise.resolve(undefined) : fetch("textmate-worker.js")] as const);
  if (resources.some(resource => resource && !resource.ok)) throw new Error("Java tokenizer resources are unavailable");
  const [wasm, grammarText, workerSource] = await Promise.all([resources[0].arrayBuffer(), resources[1].text(), resources[2]?.text()]);
  const { registry, grammar } = await createJavaGrammar(wasm, grammarText);
  const theme = StandaloneServices.get(IStandaloneThemeService);
  const languageID = StandaloneServices.get(ILanguageService).languageIdCodec.encodeLanguageId("java");
  let url: string | undefined;
  let worker: Worker;
  const revokeWorkerURL = () => { if (url) URL.revokeObjectURL(url); };
  try {
    if (resourcesConfig.createWorker) worker = resourcesConfig.createWorker();
    else {
      url = URL.createObjectURL(new Blob([workerSource!], { type: "text/javascript" }));
      worker = new Worker(url);
    }
  } catch (error) { revokeWorkerURL(); registry.dispose(); throw error; }
  type Binding = { model: any; store: any; completed: number; received: number; waiters: Set<{ resolve: () => void; reject: (error: Error) => void }> };
  const bindings = new Map<number, Binding>();
  let nextID = 0;
  let failure: Error | undefined;
  const ready = new Promise<void>((resolve, reject) => {
    const deadline = setTimeout(() => reject(new Error("Java tokenizer worker startup timed out")), 10_000);
    worker.onmessage = ({ data }) => {
      if (data.type === "ready") { clearTimeout(deadline); resolve(); }
      else if (data.type === "error") { clearTimeout(deadline); reject(new Error(data.message)); }
    };
    worker.onerror = event => { clearTimeout(deadline); reject(new Error(event.message)); };
  });
  worker.postMessage({ type: "init", wasm, grammar: grammarText });
  try { await ready; } catch (error) { worker.terminate(); revokeWorkerURL(); registry.dispose(); throw error; }
  function encoded(tokens: any[], length: number, endOffsets: boolean) {
    const data = new Uint32Array(tokens.length * 2);
    for (let i = 0; i < tokens.length; i++) {
      data[i * 2] = endOffsets ? Math.min(tokens[i].endIndex, length) : tokens[i].startIndex;
      data[i * 2 + 1] = theme.getColorTheme().tokenTheme.match(languageID, tokenRole(tokens[i].scopes)) | 1024;
    }
    return data;
  }
  const fail = (error: Error) => {
    if (failure) return;
    failure = error;
    console.error(error);
    for (const binding of bindings.values()) for (const waiter of binding.waiters) waiter.reject(error);
    worker.terminate();
    // Recreate backends with Monaco’s bounded default background tokenizer.
    TokenizationRegistry.handleChange(["java"]);
  };
  worker.onerror = event => fail(new Error(event.message));
  worker.onmessage = ({ data }) => {
    if (data.type === "error") { fail(new Error(data.message)); return; }
    const binding = bindings.get(data.id);
    if (!binding || binding.model.isDisposed() || binding.model.getVersionId() !== data.version) return;
    binding.received += data.rows.length;
    const builder = new ContiguousMultilineTokensBuilder();
    for (const row of data.rows) {
      builder.add(row.line, encoded(row.tokens, binding.model.getLineLength(row.line), true));
      binding.store.setEndState(row.line, applyStateStackDiff(INITIAL, row.state));
    }
    binding.store.setTokens(builder.finalize());
    if (data.complete) {
      binding.completed = data.version;
      binding.store.backgroundTokenizationFinished();
      for (const waiter of binding.waiters) waiter.resolve();
    }
  };
  const registration = TokenizationRegistry.register("java", {
    getInitialState: () => INITIAL,
    tokenize(line: string, _hasEOL: boolean, state: any) {
      const result = tokenizeLineWithinLimit(grammar, line, state);
      return new TokenizationResult(result.tokens.map(token => new Token(token.startIndex, tokenRole(token.scopes), "java")), result.ruleStack);
    },
    tokenizeEncoded(line: string, _hasEOL: boolean, state: any) {
      const result = tokenizeLineWithinLimit(grammar, line, state);
      return new EncodedTokenizationResult(encoded(result.tokens, line.length, false), result.ruleStack);
    },
    createBackgroundTokenizer(model: any, store: any) {
      if (failure) return undefined;
      const id = ++nextID;
      const binding: Binding = { model, store, completed: -1, received: 0, waiters: new Set() };
      bindings.set(id, binding);
      const open = () => worker.postMessage({ type: "open", id, lines: model.getLinesContent(), version: model.getVersionId(), visible: model.isAttachedToEditor() });
      // Monaco creates its token backend inside the model constructor, before
      // assigning the initial version. Mirror only after construction completes.
      let opened = false;
      queueMicrotask(() => {
        if (!bindings.has(id) || model.isDisposed()) return;
        opened = true; open();
      });
      const edits = model.onDidChangeContent((event: any) => {
        if (!opened) return;
        binding.completed = -1;
        if (event.isFlush) open();
        else worker.postMessage({ type: "edit", id, version: event.versionId, changes: event.changes });
      });
      const attached = model.onDidChangeAttached(() => worker.postMessage({ type: "visible", id, visible: model.isAttachedToEditor() }));
      return {
        requestTokens(start: number) { if (opened) worker.postMessage({ type: "request", id, start }); },
        dispose() {
          edits.dispose(); attached.dispose(); bindings.delete(id);
          worker.postMessage({ type: "dispose", id });
          for (const waiter of binding.waiters) waiter.reject(new Error("Tokenizer model disposed"));
        },
      };
    },
  });
  const themeChanges = theme.onDidColorThemeChange(() => TokenizationRegistry.handleChange(["java"]));
  return {
    // Event-based completion is useful for diagnostics and integration checks.
    // It has a local deadline even when a window is detached or hidden.
    whenReady(model: any): Promise<void> {
      if (failure) return Promise.reject(failure);
      const binding = [...bindings.values()].find(value => value.model === model);
      if (!binding) return Promise.reject(new Error("No tokenizer for model"));
      if (binding.completed === model.getVersionId()) return Promise.resolve();
      return new Promise((resolve, reject) => {
        const finish = (error?: Error) => { clearTimeout(deadline); binding.waiters.delete(waiter); error ? reject(error) : resolve(); };
        const waiter = { resolve: () => finish(), reject: (error: Error) => finish(error) };
        const deadline = setTimeout(() => finish(new Error(`Background tokenization timed out: version=${model.getVersionId()}, received=${binding.received}, attached=${model.isAttachedToEditor()}, bindings=${bindings.size}`)), 10_000);
        binding.waiters.add(waiter);
      });
    },
    status: () => ({ models: bindings.size, failed: !!failure, completedVersions: [...bindings.values()].map(binding => binding.completed) }),
    dispose() {
      registration.dispose(); themeChanges.dispose(); worker.terminate(); revokeWorkerURL(); registry.dispose();
      for (const binding of bindings.values()) for (const waiter of binding.waiters) waiter.reject(new Error("Tokenizer disposed"));
      bindings.clear();
    },
  };
}
