import type * as Monaco from "monaco-editor";
import { flushLspDocumentChanges } from "@/features/editor/lsp/pending-document-changes";
import type { LspSemanticTokensResponse } from "@/features/editor/lsp/semantic-token-types";
import { encodeMonacoSemanticTokens, MONACO_SEMANTIC_TOKEN_LEGEND } from "./semantic-tokens";

interface SemanticTokenClient {
  getActiveServerEntryForFile(filePath: string): unknown;
  getSemanticTokens(filePath: string): Promise<LspSemanticTokensResponse | null>;
  isDocumentOpen(filePath: string): boolean;
}

interface SemanticTokenProviderOptions {
  client: SemanticTokenClient;
  filePathFromModel(model: Monaco.editor.ITextModel): string;
  isLspModel(model: Monaco.editor.ITextModel): boolean;
  onDidChange?: Monaco.Emitter<void>["event"];
}

export function createMonacoSemanticTokenProvider({
  client,
  filePathFromModel,
  isLspModel,
  onDidChange,
}: SemanticTokenProviderOptions): Monaco.languages.DocumentSemanticTokensProvider {
  return {
    onDidChange,
    getLegend() {
      return MONACO_SEMANTIC_TOKEN_LEGEND;
    },
    async provideDocumentSemanticTokens(model, _lastResultId, cancellationToken) {
      if (cancellationToken.isCancellationRequested || !isLspModel(model)) return null;

      const filePath = filePathFromModel(model);
      if (!client.getActiveServerEntryForFile(filePath) || !client.isDocumentOpen(filePath)) {
        return null;
      }

      const modelVersion = model.getVersionId();
      const isCurrent = () =>
        !cancellationToken.isCancellationRequested &&
        !model.isDisposed() &&
        model.getVersionId() === modelVersion &&
        isLspModel(model) &&
        filePathFromModel(model) === filePath &&
        client.isDocumentOpen(filePath);
      // Monaco can request colors before the editor's document-change debounce fires.
      await flushLspDocumentChanges(filePath);
      if (!isCurrent()) return null;
      const response = await client.getSemanticTokens(filePath);
      if (
        !isCurrent() ||
        !response ||
        response.tokenTypes.length === 0
      ) {
        return null;
      }

      const data = encodeMonacoSemanticTokens(response, model);
      if (response.tokens.length > 0 && data.length === 0) return null;

      return {
        resultId: `${model.uri.toString()}:${modelVersion}`,
        data,
      };
    },
    releaseDocumentSemanticTokens() {},
  };
}
