import { mapCompletionKind } from "@lithe/editor/completion-kind";
import { editor as monacoEditor, Emitter, languages, Range as MonacoRange, Uri } from "monaco-editor";
import type * as Monaco from "monaco-editor";
// Ctrl+hover underline for go-to-definition.
import "monaco-editor/esm/vs/editor/contrib/gotoSymbol/browser/link/goToDefinitionAtPosition.js";
import type { CompletionItem, Hover } from "vscode-languageserver-protocol";
import { listen } from "@tauri-apps/api/event";
import {
  isDocumentFeatureAvailable,
  LspClient,
} from "@/features/editor/lsp/lsp-client";
import { formatHoverContents } from "@/features/editor/lsp/hover-content";
import {
  lspDocumentTargetForEditorPath,
  type LspDocumentTarget,
} from "@/features/editor/lsp/lsp-document-target";
import { flushLspDocumentChanges } from "@/features/editor/lsp/pending-document-changes";
import { useLspStore } from "@/features/editor/lsp/stores/lsp.store";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import {
  collectWorkspaceTextEdits,
  filePathFromUri,
  isWorkspaceEdit,
  type LspTextEdit,
} from "@/features/editor/lsp/workspace-edit";
import { MONACO_HIGHLIGHT_LANGUAGE_IDS } from "./language";
import {
  attachLspCompletionOrigin,
  lspCompletionOrigin,
  mergeResolvedCompletionSuggestion,
  toMonacoCompletionSuggestion,
} from "./lsp-completion";
import { filePathFromLitheModelUri } from "./model-uri";
import { createMonacoSemanticTokenProvider } from "./semantic-token-provider";

let providersRegistered = false;

function filePathFromModel(model: Monaco.editor.ITextModel): string {
  if (model.uri.scheme === "file") {
    return filePathFromUri(model.uri.toString());
  }

  if (model.uri.scheme !== "lithe") {
    return decodeURIComponent(model.uri.path);
  }

  return filePathFromLitheModelUri(model.uri.path, model.uri.query);
}

function toMonacoRange(range: {
  start: { line: number; character: number };
  end: { line: number; character: number };
}) {
  return new MonacoRange(
    range.start.line + 1,
    range.start.character + 1,
    range.end.line + 1,
    range.end.character + 1,
  );
}

function toMonacoLocationUri(uri: string): Monaco.Uri {
  return uri.startsWith("file://") || !uri.includes("://")
    ? Uri.file(filePathFromUri(uri))
    : Uri.parse(uri);
}

function toMonacoTextEdit(edit: LspTextEdit): Monaco.languages.TextEdit {
  return {
    range: toMonacoRange(edit.range),
    text: edit.newText,
  };
}

function toCompletionItem(
  item: CompletionItem,
  range: Monaco.IRange,
): Monaco.languages.CompletionItem {
  const suggestion = toMonacoCompletionSuggestion(item, range);
  return {
    label: suggestion.label,
    kind: mapCompletionKind(item.kind),
    detail: suggestion.detail,
    documentation: suggestion.documentation,
    insertText: suggestion.insertText,
    range: suggestion.range,
    sortText: suggestion.sortText,
    filterText: suggestion.filterText,
    additionalTextEdits: suggestion.additionalTextEdits,
    commitCharacters: item.commitCharacters,
    insertTextRules: suggestion.snippet
      ? languages.CompletionItemInsertTextRule.InsertAsSnippet
      : undefined,
  };
}

function hoverToMarkdown(hover: Hover | null): Monaco.IMarkdownString[] {
  if (!hover?.contents) return [];
  const value = formatHoverContents(hover.contents);
  return value ? [{ value }] : [];
}

function codeActionKind(kind: string | undefined): string {
  if (!kind) return "quickfix";
  if (kind.startsWith("quickfix")) return "quickfix";
  if (kind.startsWith("refactor")) return "refactor";
  if (kind.startsWith("source")) return "source";
  return kind;
}

function getPayloadEdit(payload: unknown): unknown {
  if (!payload || typeof payload !== "object") return null;
  return (payload as { edit?: unknown }).edit;
}

function toWorkspaceEdit(edit: unknown): Monaco.languages.WorkspaceEdit | undefined {
  if (!isWorkspaceEdit(edit)) return undefined;

  const edits: Monaco.languages.IWorkspaceTextEdit[] = [];
  for (const [filePath, textEdits] of collectWorkspaceTextEdits(edit)) {
    const resource = Uri.file(filePath);
    for (const textEdit of textEdits) {
      edits.push({
        resource,
        textEdit: toMonacoTextEdit(textEdit),
        versionId: undefined,
      });
    }
  }

  return edits.length > 0 ? { edits } : undefined;
}

export function registerMonacoLspProviders() {
  if (providersRegistered) return;
  providersRegistered = true;

  const selector = Array.from(MONACO_HIGHLIGHT_LANGUAGE_IDS);
  const lspClient = LspClient.getInstance();
  const availableTarget = (model: Monaco.editor.ITextModel, feature: string) => {
    const target = lspDocumentTargetForEditorPath(
      useBufferStore.getState().buffers,
      filePathFromModel(model),
    );
    return target && isDocumentFeatureAvailable(lspClient.getDocumentAvailability(target, feature))
      ? target
      : null;
  };

  const completionOrigins = new WeakMap<
    Monaco.languages.CompletionItem,
    { item: CompletionItem; target: LspDocumentTarget; range: Monaco.IRange }
  >();
  languages.registerCompletionItemProvider(selector, {
    triggerCharacters: [".", ":", "<", '"', "'", "/", "@", "#", "$", "\\"],
    async provideCompletionItems(model, position) {
      const target = availableTarget(model, "completion");
      if (!target) return { suggestions: [] };

      // This request comes from the keystroke that produced the current word,
      // whose document change is still waiting out the debounce. Servers answer
      // completion from the text they hold, so without flushing the cursor sits
      // one character past what they know and the answer is empty.
      await flushLspDocumentChanges(target.filePath);
      const completions = await lspClient.getCompletions(
        target,
        position.lineNumber - 1,
        position.column - 1,
      );
      const word = model.getWordUntilPosition(position);
      const range = new MonacoRange(
        position.lineNumber,
        word.startColumn,
        position.lineNumber,
        word.endColumn,
      );

      return {
        suggestions: completions.map((item) => {
          const suggestion = toCompletionItem(item, range);
          const origin = { item, target, range };
          completionOrigins.set(suggestion, origin);
          return attachLspCompletionOrigin(suggestion, origin);
        }),
      };
    },
    async resolveCompletionItem(item, token) {
      const origin =
        lspCompletionOrigin<LspDocumentTarget>(item) ?? completionOrigins.get(item);
      if (!origin) return item;
      const availability = lspClient.getDocumentAvailability(origin.target, "completionResolve");
      if (availability.phase === "ready" && availability.feature === "unsupported") {
        return item;
      }
      const resolved = await lspClient.resolveCompletion(origin.target, origin.item);
      if (!resolved || token.isCancellationRequested) return item;
      const merged = mergeResolvedCompletionSuggestion(
        toMonacoCompletionSuggestion(origin.item, origin.range),
        resolved,
        origin.range,
      );
      return {
        ...item,
        label: merged.label,
        insertText: merged.insertText,
        range: merged.range,
        detail: merged.detail,
        documentation: merged.documentation,
        filterText: merged.filterText,
        sortText: merged.sortText,
        additionalTextEdits: merged.additionalTextEdits,
        insertTextRules: merged.snippet
          ? languages.CompletionItemInsertTextRule.InsertAsSnippet
          : item.insertTextRules,
      };
    },
  });

  languages.registerHoverProvider(selector, {
    async provideHover(model, position) {
      const target = availableTarget(model, "hover");
      if (!target) return null;

      const hover = await lspClient.getHover(target, position.lineNumber - 1, position.column - 1);
      const contents = hoverToMarkdown(hover);
      return contents.length > 0 ? { contents } : null;
    },
  });

  // A definition provider makes Monaco underline symbols on Ctrl+hover.
  // The actual target locations are intentionally returned as the current
  // cursor range so Monaco never tries to open a model it cannot find.
  // Navigation is handled entirely by the registerEditorOpener below, which
  // calls Lithe's own buffer pipeline for both physical files and virtual
  // (decompiled) documents.
  languages.registerDefinitionProvider(selector, {
    async provideDefinition(model, position) {
      const target = availableTarget(model, "definition");
      if (!target) return [];

      const locations = await lspClient.getDefinition(
        target,
        position.lineNumber - 1,
        position.column - 1,
      );
      if (!locations || locations.length === 0) return [];

      // Return the word range at the cursor so Monaco draws the underline,
      // but keep the URI pointing at the current model so no external model
      // lookup is triggered. The opener intercepts Ctrl+Click and does the
      // real navigation with the LSP location.
      const word = model.getWordAtPosition(position);
      const wordRange = word
        ? new MonacoRange(
            position.lineNumber,
            word.startColumn,
            position.lineNumber,
            word.endColumn,
          )
        : new MonacoRange(
            position.lineNumber,
            position.column,
            position.lineNumber,
            position.column,
          );
      return [{ uri: model.uri, range: wordRange }];
    },
  });

  // Route Monaco-initiated navigation (Ctrl+Click, peek "open") through
  // Lithe's buffer pipeline instead of Monaco's model resolver.
  monacoEditor.registerEditorOpener({
    openCodeEditor(source, resource, selectionOrPosition) {
      const sourceModel = "getModel" in source ? (source as Monaco.editor.ICodeEditor).getModel() : null;
      if (!sourceModel) return false;
      const sourcePath = filePathFromModel(sourceModel);
      const range = MonacoRange.isIRange(selectionOrPosition)
        ? selectionOrPosition
        : selectionOrPosition
          ? {
              startLineNumber: selectionOrPosition.lineNumber,
              startColumn: selectionOrPosition.column,
              endLineNumber: selectionOrPosition.lineNumber,
              endColumn: selectionOrPosition.column,
            }
          : { startLineNumber: 1, startColumn: 1, endLineNumber: 1, endColumn: 1 };

      void (async () => {
        const [{ openLspNavigationLocation }, { readFileContent }] = await Promise.all([
          import("@/features/editor/lsp/navigation-target"),
          import("@/features/file-system/controllers/file-operations"),
        ]);
        const bufferStore = useBufferStore.getState();
        await openLspNavigationLocation({
          location: {
            uri: resource.scheme === "file" ? resource.toString() : resource.toString(),
            range: {
              start: { line: range.startLineNumber - 1, character: range.startColumn - 1 },
              end: { line: range.endLineNumber - 1, character: range.endColumn - 1 },
            },
          },
          sourceFilePath: sourcePath,
          buffers: bufferStore.buffers,
          actions: bufferStore.actions,
          getVirtualDocument: (filePath, virtualUri) =>
            lspClient.getVirtualDocument(filePath, virtualUri),
          readFileContent,
        });
        window.dispatchEvent(
          new CustomEvent("menu-go-to-line", {
            detail: {
              line: range.startLineNumber,
              column: range.startColumn,
            },
          }),
        );
      })();
      return true;
    },
  });

  // Semantic highlighting: colors types, fields, and methods beyond what the
  // Monarch grammar can express. Re-requested whenever the language server
  // connects or its feature set changes, because the first request usually
  // races server startup and returns nothing.
  const semanticTokensChanged = new Emitter<void>();
  useLspStore.subscribe((state, previousState) => {
    if (
      state.lspStatus.status !== previousState.lspStatus.status ||
      state.lspStatus.documentRevision !== previousState.lspStatus.documentRevision
    ) {
      semanticTokensChanged.fire();
    }
  });
  void listen("lsp://features-changed", () => semanticTokensChanged.fire());
  languages.registerDocumentSemanticTokensProvider(
    selector,
    createMonacoSemanticTokenProvider({
      client: lspClient,
      filePathFromModel,
      isLspModel: (model) => model.uri.scheme === "file" || model.uri.scheme === "lithe",
      onDidChange: semanticTokensChanged.event,
    }),
  );

  languages.registerImplementationProvider(selector, {
    async provideImplementation(model, position) {
      const target = availableTarget(model, "implementation");
      if (!target) return [];

      const locations = await lspClient.getImplementation(
        target,
        position.lineNumber - 1,
        position.column - 1,
      );
      return (locations ?? []).map((location) => ({
        uri: toMonacoLocationUri(location.uri),
        range: toMonacoRange(location.range),
      }));
    },
  });

  languages.registerTypeDefinitionProvider(selector, {
    async provideTypeDefinition(model, position) {
      const target = availableTarget(model, "typeDefinition");
      if (!target) return [];

      const locations = await lspClient.getTypeDefinition(
        target,
        position.lineNumber - 1,
        position.column - 1,
      );
      return (locations ?? []).map((location) => ({
        uri: toMonacoLocationUri(location.uri),
        range: toMonacoRange(location.range),
      }));
    },
  });

  languages.registerReferenceProvider(selector, {
    async provideReferences(model, position) {
      const target = availableTarget(model, "references");
      if (!target) return [];

      const locations = await lspClient.getReferences(
        target,
        position.lineNumber - 1,
        position.column - 1,
      );
      return (locations ?? []).map((location) => ({
        uri: toMonacoLocationUri(location.uri),
        range: toMonacoRange(location.range),
      }));
    },
  });

  languages.registerRenameProvider(selector, {
    async resolveRenameLocation(model, position) {
      const target = availableTarget(model, "rename");
      if (!target) {
        return {
          range: new MonacoRange(
            position.lineNumber,
            position.column,
            position.lineNumber,
            position.column,
          ),
          text: "",
        };
      }

      const word = model.getWordAtPosition(position);
      return {
        range: word
          ? new MonacoRange(
              position.lineNumber,
              word.startColumn,
              position.lineNumber,
              word.endColumn,
            )
          : new MonacoRange(
              position.lineNumber,
              position.column,
              position.lineNumber,
              position.column,
            ),
        text: word?.word || "",
      };
    },
    async provideRenameEdits(model, position, newName) {
      const target = availableTarget(model, "rename");
      if (!target) return undefined;

      const edit = await lspClient.rename(
        target,
        position.lineNumber - 1,
        position.column - 1,
        newName,
      );
      return toWorkspaceEdit(edit);
    },
  });

  languages.registerCodeActionProvider(selector, {
    async provideCodeActions(model, _range, context) {
      const target = availableTarget(model, "codeActions");
      if (!target) return { actions: [], dispose: () => {} };

      const actions: Monaco.languages.CodeAction[] = [];
      for (const marker of context.markers.slice(0, 3)) {
        const diagnostic = {
          severity: marker.severity === 8 ? "error" : marker.severity === 4 ? "warning" : "info",
          filePath: target.filePath,
          line: marker.startLineNumber - 1,
          column: marker.startColumn - 1,
          endLine: marker.endLineNumber - 1,
          endColumn: marker.endColumn - 1,
          message: marker.message,
          source: marker.source,
          code: typeof marker.code === "string" ? marker.code : undefined,
        } as const;
        const lspActions = await lspClient.getCodeActions(target, diagnostic);
        for (const action of lspActions) {
          if (action.disabledReason) continue;
          const edit = toWorkspaceEdit(getPayloadEdit(action.payload));
          if (!edit) continue;
          actions.push({
            title: action.title,
            kind: codeActionKind(action.kind),
            diagnostics: [marker],
            isPreferred: action.isPreferred,
            edit,
          });
        }
      }

      return { actions, dispose: () => {} };
    },
  });
}
