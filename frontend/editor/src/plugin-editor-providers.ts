import * as monaco from "monaco-editor/esm/vs/editor/editor.api.js";
import { Emitter } from "monaco-editor/esm/vs/base/common/event.js";
import { StandaloneServices } from "monaco-editor/esm/vs/editor/standalone/browser/standaloneServices.js";
import { IOpenerService } from "monaco-editor/esm/vs/platform/opener/common/opener.js";
import { mapCompletionKind } from "./completion-kind";
import { MONACO_SEMANTIC_TOKEN_LEGEND, encodeMonacoSemanticTokens } from "./semantic-tokens";
import {
  foldingSpans, hoverSections, lensItems, linkItems, linkUrl, mergeSemanticResponses, parseLinkUrl, toSpan,
  type FoldingSpan,
} from "./plugin-editor-provider-rules";

type Entry = {
  model: monaco.editor.ITextModel; revision: number; chain: Promise<unknown>;
  readonly: boolean; frozen: boolean; closingHolds?: number;
};
type Answer<E extends Entry> = { id: string; entry: E; revision: number; reply: any; current: () => boolean };
type Origin<E extends Entry> = { id: string; entry: E; revision: number; current: () => boolean };

// Monaco needs the characters that start a completion when it registers the
// provider, but a plugin names its own. Listening for all ASCII punctuation
// lets any of them through; the host passes a typed character only to
// registrations that asked for it and answers nothing otherwise.
const COMPLETION_TRIGGERS = [..."!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"];
const LENS_COMMAND = "lithe.pluginCodeLens";
const MAX_LINK_BATCHES = 64;

const foldingKind = (kind: FoldingSpan["kind"]) => {
  const kinds = monaco.languages.FoldingRangeKind;
  return kind === "comment" ? kinds.Comment : kind === "imports" ? kinds.Imports : kind === "region" ? kinds.Region : undefined;
};

/**
 * Editor providers that plugins register (API-25). The page only names a
 * provider type and a position; the host calls the plugins, validates and
 * merges their answers, and keeps every private reference behind opaque keys.
 * Each provider here only supplements the language server's own: Monaco asks
 * all providers and combines hovers, completions, lenses, folding ranges and
 * links. Definitions are answered by the host's own navigation.
 */
export function attachPluginEditorProviders<E extends Entry>(host: {
  entries(): Map<string, E>;
  request(payload: object): Promise<any>;
  current(id: string, entry: E): () => boolean;
}) {
  const lensChanges = new Emitter<void>();
  const foldingChanges = new Emitter<void>();
  const semanticChanges = new Emitter<void>();
  const linkOrigins = new Map<string, Origin<E>>();
  let disposed = false;

  /** One round trip: waits for the document to settle, asks, and drops the answer if it went stale. */
  async function ask(model: monaco.editor.ITextModel, token: monaco.CancellationToken, body: object): Promise<Answer<E> | undefined> {
    const pair = [...host.entries()].find(([, entry]) => entry.model === model);
    if (!pair || disposed) return undefined;
    const [id, entry] = pair, current = host.current(id, entry);
    await entry.chain;
    if (disposed || !current() || token.isCancellationRequested || model.isDisposed()) return undefined;
    const revision = entry.revision;
    const reply = await host.request({ type: "pluginEditorProviders", id, revision, language: model.getLanguageId(), ...body });
    if (disposed || !current() || token.isCancellationRequested || model.isDisposed() || entry.revision !== revision ||
        reply?.cancelled) return undefined;
    return { id, entry, revision, reply, current };
  }

  const hover = monaco.languages.registerHoverProvider("*", {
    async provideHover(model, position, token) {
      const answer = await ask(model, token, { provider: "hover", line: position.lineNumber - 1, character: position.column - 1 });
      const contents = answer ? hoverSections(answer.reply) : [];
      if (!answer || !contents.length) return null;
      const span = toSpan(answer.reply.range, model.getLineCount());
      return { contents, range: span ? model.validateRange(span) : undefined };
    },
  });

  function suggestion(model: monaco.editor.ITextModel, item: any, fallback: monaco.Range): monaco.languages.CompletionItem | undefined {
    if (typeof item?.label !== "string") return undefined;
    const lineCount = model.getLineCount();
    const valid = (range: unknown) => { const span = toSpan(range, lineCount); return span && model.validateRange(span); };
    let range: monaco.languages.CompletionItem["range"] = fallback;
    let insertText = typeof item.insertText === "string" ? item.insertText : item.label;
    if (item.textEdit) {
      insertText = item.textEdit.newText;
      if (item.textEdit.range) {
        const edit = valid(item.textEdit.range);
        if (!edit) return undefined;
        range = edit;
      } else {
        const insert = valid(item.textEdit.insert), replace = valid(item.textEdit.replace);
        if (!insert || !replace) return undefined;
        range = { insert, replace };
      }
    }
    const additionalTextEdits: monaco.languages.TextEdit[] = [];
    for (const edit of Array.isArray(item.additionalTextEdits) ? item.additionalTextEdits : []) {
      const editRange = valid(edit?.range);
      if (!editRange || typeof edit.newText !== "string") return undefined;
      additionalTextEdits.push({ range: editRange, text: edit.newText });
    }
    const documentation = item.documentation
      ? item.documentation.kind === "markdown"
        ? { value: item.documentation.value, isTrusted: false, supportHtml: false } : item.documentation.value
      : undefined;
    return {
      label: item.labelDetails ? { label: item.label, detail: item.labelDetails.detail, description: item.labelDetails.description } : item.label,
      kind: mapCompletionKind(item.kind),
      insertText, range, documentation,
      insertTextRules: item.insertTextFormat === 2 ? monaco.languages.CompletionItemInsertTextRule.InsertAsSnippet : undefined,
      detail: item.detail, sortText: item.sortText, filterText: item.filterText,
      tags: Array.isArray(item.tags) && item.tags.includes(1) ? [monaco.languages.CompletionItemTag.Deprecated] : undefined,
      commitCharacters: item.commitCharacters,
      additionalTextEdits: additionalTextEdits.length ? additionalTextEdits : undefined,
    };
  }

  const completion = monaco.languages.registerCompletionItemProvider("*", {
    triggerCharacters: COMPLETION_TRIGGERS,
    async provideCompletionItems(model, position, context, token) {
      const triggered = context.triggerKind === monaco.languages.CompletionTriggerKind.TriggerCharacter &&
        typeof context.triggerCharacter === "string";
      const answer = await ask(model, token, { provider: "completion", line: position.lineNumber - 1, character: position.column - 1,
        ...(triggered ? { triggerCharacter: context.triggerCharacter } : {}) });
      if (!answer) return { suggestions: [] };
      const word = model.getWordUntilPosition(position);
      const fallback = new monaco.Range(position.lineNumber, word.startColumn, position.lineNumber, word.endColumn);
      return {
        incomplete: answer.reply.isIncomplete === true,
        suggestions: (Array.isArray(answer.reply.items) ? answer.reply.items : [])
          .flatMap((item: unknown) => suggestion(model, item, fallback) ?? []),
      };
    },
  });

  // A lens click names the host's opaque batch and key; the host runs the
  // plugin function and the page learns nothing about it.
  const lensCommand = monaco.editor.registerCommand(LENS_COMMAND, async (_accessor, context: Origin<E> & { batch: string; lens: string }) => {
    const { id, entry, revision, batch, lens, current } = context;
    if (disposed || !current() || host.entries().get(id) !== entry || entry.model.isDisposed() || entry.revision !== revision ||
        entry.readonly || entry.frozen || entry.closingHolds) return;
    await host.request({ type: "pluginEditorProviderCommand", id, revision, batch, lens });
  });
  const codeLens: monaco.languages.CodeLensProvider = {
    onDidChange: listener => lensChanges.event(() => listener(codeLens)),
    async provideCodeLenses(model, token) {
      const answer = await ask(model, token, { provider: "codeLens" });
      const { batch, lenses } = lensItems(answer?.reply, model.getLineCount());
      return {
        lenses: !answer ? [] : lenses.map(item => ({
          range: model.validateRange(item.range),
          command: { id: LENS_COMMAND, title: item.title,
            arguments: [{ id: answer.id, entry: answer.entry, revision: answer.revision, current: answer.current, batch, lens: item.id }] },
        })),
        dispose() {},
      };
    },
  };
  const codeLensRegistration = monaco.languages.registerCodeLensProvider("*", codeLens);

  const folding: monaco.languages.FoldingRangeProvider = {
    onDidChange: listener => foldingChanges.event(() => listener(folding)),
    async provideFoldingRanges(model, _context, token) {
      const answer = await ask(model, token, { provider: "foldingRange" });
      if (!answer) return null;
      const ranges = foldingSpans(answer.reply, model.getLineCount())
        .map(span => ({ start: span.start, end: span.end, kind: foldingKind(span.kind) }));
      return ranges.length ? ranges : null;
    },
  };
  const foldingRegistration = monaco.languages.registerFoldingRangeProvider("*", folding);

  // A "*" registration scores below one for the document's own language, so
  // this runs only for files whose language has no semantic tokens of its
  // own; where the language server provides them, theirs stay.
  const semanticTokens = monaco.languages.registerDocumentSemanticTokensProvider("*", {
    getLegend: () => MONACO_SEMANTIC_TOKEN_LEGEND,
    onDidChange: semanticChanges.event,
    releaseDocumentSemanticTokens() {},
    async provideDocumentSemanticTokens(model, _lastResultID, token) {
      const answer = await ask(model, token, { provider: "semanticTokens" });
      if (!answer) return null;
      const merged = mergeSemanticResponses(answer.reply.responses);
      return merged.tokens.length ? { data: encodeMonacoSemanticTokens(merged, model) } : null;
    },
  });

  // Link targets stay in the host: the page draws a link that carries only
  // an opaque URL of its own scheme, and the opener below sends the click
  // back. Monaco would otherwise act on a plugin's own URL (`command:` runs
  // editor commands), so no plugin URL reaches Monaco at all.
  const linkProvider: monaco.languages.LinkProvider = {
    async provideLinks(model, token) {
      const answer = await ask(model, token, { provider: "documentLink" });
      const { batch, links } = linkItems(answer?.reply, model.getLineCount());
      if (!answer || !links.length) return { links: [] };
      for (const [key, origin] of linkOrigins) if (origin.entry === answer.entry) linkOrigins.delete(key);
      if (linkOrigins.size >= MAX_LINK_BATCHES) linkOrigins.delete(linkOrigins.keys().next().value!);
      linkOrigins.set(batch, { id: answer.id, entry: answer.entry, revision: answer.revision, current: answer.current });
      return { links: links.map(item => ({ range: model.validateRange(item.range), url: linkUrl(batch, item.id), tooltip: item.tooltip })) };
    },
  };
  let linkRegistration = monaco.languages.registerLinkProvider("*", linkProvider);
  const opener = StandaloneServices.get(IOpenerService).registerOpener({
    async open(resource) {
      const target = parseLinkUrl(String(resource));
      if (!target) return false;
      const origin = linkOrigins.get(target.batch);
      // A link from a list that is no longer current is swallowed, not handed to the browser.
      if (origin && !disposed && origin.current() && host.entries().get(origin.id) === origin.entry &&
          origin.entry.revision === origin.revision && !origin.entry.frozen && !origin.entry.closingHolds)
        await host.request({ type: "pluginEditorProviderLink", id: origin.id, revision: origin.revision, batch: target.batch, link: target.id });
      return true;
    },
  });

  return {
    /** Every registration changed: ask again for what the page already shows. */
    refresh() {
      if (disposed) return;
      linkOrigins.clear();
      lensChanges.fire(); foldingChanges.fire(); semanticChanges.fire();
      // Links have no change event of their own; registering again makes Monaco recompute them.
      linkRegistration.dispose();
      linkRegistration = monaco.languages.registerLinkProvider("*", linkProvider);
    },
    dispose() {
      disposed = true;
      linkOrigins.clear();
      for (const registration of [hover, completion, lensCommand, codeLensRegistration, foldingRegistration, semanticTokens, linkRegistration, opener])
        registration.dispose();
      lensChanges.dispose(); foldingChanges.dispose(); semanticChanges.dispose();
    },
  };
}
