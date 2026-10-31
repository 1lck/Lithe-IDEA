/// <reference path="./monaco-tokenization-internals.d.ts" />
import type { editor, languages } from "monaco-editor";
import { TokenizationRegistry, Token, TokenizationResult, EncodedTokenizationResult } from "monaco-editor/esm/vs/editor/common/languages.js";
import { ContiguousMultilineTokensBuilder } from "monaco-editor/esm/vs/editor/common/tokens/contiguousMultilineTokensBuilder.js";
import { StandaloneServices } from "monaco-editor/esm/vs/editor/standalone/browser/standaloneServices.js";
import { IStandaloneThemeService } from "monaco-editor/esm/vs/editor/standalone/common/standaloneTheme.js";
import { ILanguageService } from "monaco-editor/esm/vs/editor/common/languages/language.js";

class PlainState implements languages.IState {
  clone() { return this; }
  equals(other: languages.IState) { return other instanceof PlainState; }
}
const plain = new PlainState();
let workerSource: Promise<string> | undefined;

/** Regex execution is isolated behind a terminable worker with a local deadline. */
export function installPluginGrammar(languageID: string, grammar: languages.IMonarchLanguage) {
  const previous = TokenizationRegistry.get(languageID);
  const theme = StandaloneServices.get(IStandaloneThemeService);
  const encodedID = StandaloneServices.get(ILanguageService).languageIdCodec.encodeLanguageId(languageID);
  type Binding = { model: editor.ITextModel; store: import("monaco-editor/esm/vs/editor/common/languages.js").BackgroundTokenStore; pending: boolean; debounce?: ReturnType<typeof setTimeout> };
  const bindings = new Map<number, Binding>();
  let nextID = 0, worker: Worker | undefined, url: string | undefined, stopped = false, ready = false;
  let deadline: ReturnType<typeof setTimeout> | undefined;
  const stop = (error?: unknown) => {
    if (stopped) return;
    stopped = true; clearTimeout(deadline); worker?.terminate(); if (url) URL.revokeObjectURL(url);
    for (const binding of bindings.values()) {
      clearTimeout(binding.debounce); binding.pending = false;
      if (error && !binding.model.isDisposed()) {
        const builder = new ContiguousMultilineTokensBuilder();
        for (let line = 1; line <= binding.model.getLineCount(); line++) {
          builder.add(line, new Uint32Array([binding.model.getLineLength(line),
            theme.getColorTheme().tokenTheme.match(encodedID, "") | 1024]));
          binding.store.setEndState(line, plain);
        }
        binding.store.setTokens(builder.finalize());
      }
      binding.store.backgroundTokenizationFinished();
    }
    if (error) console.warn("Plugin tokenizer stopped", languageID, String(error));
  };
  const watch = () => {
    clearTimeout(deadline);
    if (!stopped) deadline = setTimeout(() => stop("worker exceeded its execution budget"), 2000);
  };
  const open = (id: number, binding: Binding) => {
    if (!worker || !ready || stopped || binding.model.isDisposed()) return;
    // Large buffers remain editable/plain, and cannot flood a worker queue.
    if (binding.model.getValueLength() > 128 * 1024 || binding.model.getLineCount() > 10_000) {
      binding.pending = false; binding.store.backgroundTokenizationFinished(); return;
    }
    binding.pending = true;
    worker.postMessage({ type: "open", id, version: binding.model.getVersionId(), lines: binding.model.getLinesContent() });
    if (!deadline) watch();
  };
  const registration = TokenizationRegistry.register(languageID, {
    getInitialState: () => plain,
    tokenize(line) { return new TokenizationResult([new Token(0, "", languageID)], plain); },
    tokenizeEncoded() { return new EncodedTokenizationResult(new Uint32Array([0, theme.getColorTheme().tokenTheme.match(encodedID, "") | 1024]), plain); },
    createBackgroundTokenizer(model, store) {
      const id = ++nextID, binding: Binding = { model, store, pending: false };
      bindings.set(id, binding);
      const changed = model.onDidChangeContent(() => {
        clearTimeout(binding.debounce);
        binding.debounce = setTimeout(() => open(id, binding), 80);
      });
      queueMicrotask(() => open(id, binding));
      return {
        requestTokens() { if (!binding.pending) open(id, binding); },
        dispose() {
          changed.dispose(); clearTimeout(binding.debounce); bindings.delete(id);
          worker?.postMessage({ type: "dispose", id });
          if (![...bindings.values()].some(value => value.pending)) { clearTimeout(deadline); deadline = undefined; }
        },
      };
    },
  });
  workerSource ??= fetch("textmate-worker.js").then(response => {
    if (!response.ok) throw new Error("Tokenizer worker unavailable");
    return response.text();
  });
  watch();
  void workerSource.then(source => {
    if (stopped) return;
    url = URL.createObjectURL(new Blob([source], { type: "text/javascript" }));
    worker = new Worker(url);
    worker.onerror = event => stop(event.message);
    worker.onmessage = ({ data }) => {
      if (stopped) return;
      if (data.type === "error") { stop(data.message); return; }
      clearTimeout(deadline); deadline = undefined;
      if (data.type === "ready") {
        ready = true;
        for (const [id, binding] of bindings) open(id, binding);
      } else {
        const binding = bindings.get(data.id);
        if (binding && !binding.model.isDisposed() && binding.model.getVersionId() === data.version) {
          const builder = new ContiguousMultilineTokensBuilder();
          for (const row of data.rows ?? []) {
            const tokens = new Uint32Array(row.tokens.length * 2);
            for (let i = 0; i < row.tokens.length; i++) {
              tokens[i * 2] = row.tokens[i + 1]?.offset ?? binding.model.getLineLength(row.line);
              tokens[i * 2 + 1] = theme.getColorTheme().tokenTheme.match(encodedID, row.tokens[i].type) | 1024;
            }
            builder.add(row.line, tokens); binding.store.setEndState(row.line, plain);
          }
          binding.store.setTokens(builder.finalize());
          if (data.complete) { binding.pending = false; binding.store.backgroundTokenizationFinished(); }
        } else if (binding && data.complete) { binding.pending = false; }
      }
      if ([...bindings.values()].some(binding => binding.pending) && !deadline) watch();
    };
    worker.postMessage({ type: "pluginGrammar", languageID, grammar });
  }).catch(stop);
  const themeChanges = theme.onDidColorThemeChange(() => {
    for (const [id, binding] of bindings) open(id, binding);
  });
  return { dispose() {
    stop(); registration.dispose(); themeChanges.dispose(); bindings.clear();
    if (previous) TokenizationRegistry.register(languageID, previous);
  } };
}
