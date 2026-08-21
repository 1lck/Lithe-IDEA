import { editor as monacoEditor, Range as MonacoRange } from "monaco-editor";
import type * as Monaco from "monaco-editor";
import type { DefinitionNavigationHint } from "@/features/editor/lsp/definition-navigation-hint";
import {
  isEditorLspTargetSupported,
  type LspDocumentTarget,
} from "@/features/editor/lsp/lsp-document-target";
import { LspClient, type LspLocation } from "@/features/editor/lsp/lsp-client";
import { resolveLombokAccessorDefinition } from "@/features/editor/lsp/lombok-accessor-navigation";
import { logger } from "@/features/editor/utils/logger";
import { isEditorGoToDefinitionModifierActive } from "@/features/editor/utils/go-to-definition-gesture";
import { DefinitionHoverScheduler } from "./definition-link-scheduler";

const DEFINITION_HOVER_DELAY_MILLISECONDS = 150;

interface MonacoDefinitionLinkOptions {
  editor: Monaco.editor.IStandaloneCodeEditor;
  model: Monaco.editor.ITextModel;
  documentTarget: LspDocumentTarget;
  workspaceRoot?: string;
  enabled?: boolean;
}

interface DefinitionWordRequest {
  modelVersion: number;
  lineNumber: number;
  character: number;
  startColumn: number;
  endColumn: number;
}

interface DefinitionWordResolution {
  locations: LspLocation[];
}

export interface MonacoDefinitionLinkGesture extends Monaco.IDisposable {
  enabled: boolean;
  resolveForClick(position: Monaco.Position): Promise<DefinitionNavigationHint | null>;
}

function definitionWordKey(request: DefinitionWordRequest): string {
  return `${request.modelVersion}:${request.lineNumber}:${request.startColumn}:${request.endColumn}`;
}

export function registerMonacoDefinitionLinkGesture({
  editor,
  model,
  documentTarget,
  workspaceRoot,
  enabled = true,
}: MonacoDefinitionLinkOptions): MonacoDefinitionLinkGesture {
  const decorations = editor.createDecorationsCollection();
  const gestureEnabled =
    enabled && Boolean(documentTarget.filePath) && isEditorLspTargetSupported(documentTarget);
  let hoveredPosition: Monaco.Position | null = null;

  const requestAtPosition = (position: Monaco.Position): DefinitionWordRequest | null => {
    if (!gestureEnabled || model.isDisposed()) return null;
    const word = model.getWordAtPosition(position);
    if (!word) return null;
    return {
      modelVersion: model.getVersionId(),
      lineNumber: position.lineNumber,
      character: position.column - 1,
      startColumn: word.startColumn,
      endColumn: word.endColumn,
    };
  };

  const scheduler = new DefinitionHoverScheduler<DefinitionWordRequest, DefinitionWordResolution>({
    delayMilliseconds: DEFINITION_HOVER_DELAY_MILLISECONDS,
    keyOf: definitionWordKey,
    resolve: async (request) => {
      const line = request.lineNumber - 1;
      const locations =
        (await LspClient.getInstance().getDefinition(documentTarget, line, request.character)) ?? [];
      if (
        locations.length > 0 ||
        model.isDisposed() ||
        model.getLanguageId() !== "java" ||
        documentTarget.documentUri ||
        !workspaceRoot
      ) {
        return { locations };
      }

      try {
        const lombokDefinition = await resolveLombokAccessorDefinition({
          source: model.getValue(),
          sourceFilePath: documentTarget.filePath,
          workspaceRoot,
          line,
          character: request.character,
        });
        return { locations: lombokDefinition ? [lombokDefinition] : [] };
      } catch (error) {
        logger.error("DefinitionLink", "Could not resolve Lombok definition link:", error);
        return { locations: [] };
      }
    },
    onActiveResult: (request, result) => {
      if (result.locations.length === 0) {
        decorations.clear();
        return;
      }
      decorations.set([
        {
          range: new MonacoRange(
            request.lineNumber,
            request.startColumn,
            request.lineNumber,
            request.endColumn,
          ),
          options: { inlineClassName: "goto-definition-link" },
        },
      ]);
    },
    onError: (error) => {
      logger.error("DefinitionLink", "Could not resolve definition link:", error);
    },
  });

  const clearLink = () => {
    scheduler.clearActive();
    decorations.clear();
  };

  const showLink = (position: Monaco.Position) => {
    const request = requestAtPosition(position);
    if (!request) {
      clearLink();
      return;
    }
    decorations.clear();
    scheduler.activate(request);
  };

  const syncLinkForModifier = (event: {
    ctrlKey?: boolean;
    metaKey?: boolean;
    altKey?: boolean;
    shiftKey?: boolean;
  }) => {
    if (hoveredPosition && isEditorGoToDefinitionModifierActive(event)) {
      showLink(hoveredPosition);
    } else {
      clearLink();
    }
  };

  const disposables = gestureEnabled
    ? [
        editor.onMouseMove((event) => {
          if (
            event.target.type !== monacoEditor.MouseTargetType.CONTENT_TEXT ||
            !event.target.position
          ) {
            hoveredPosition = null;
            clearLink();
            return;
          }

          hoveredPosition = event.target.position;
          syncLinkForModifier(event.event);
        }),
        editor.onMouseLeave(() => {
          hoveredPosition = null;
          clearLink();
        }),
        editor.onKeyDown((event) => syncLinkForModifier(event.browserEvent)),
        editor.onKeyUp((event) => syncLinkForModifier(event.browserEvent)),
        editor.onDidChangeModelContent(() => {
          scheduler.reset();
          decorations.clear();
        }),
        editor.onDidBlurEditorWidget(clearLink),
      ]
    : [];

  return {
    enabled: gestureEnabled,
    async resolveForClick(position) {
      const request = requestAtPosition(position);
      if (!request) return null;
      const result = await scheduler.resolveNow(request);
      if (!result || model.isDisposed() || request.modelVersion !== model.getVersionId()) {
        return null;
      }
      return {
        sourceFilePath: documentTarget.filePath,
        sourceLine: request.lineNumber - 1,
        sourceStartCharacter: request.startColumn - 1,
        sourceEndCharacter: request.endColumn - 1,
        locations: result.locations,
      };
    },
    dispose() {
      scheduler.dispose();
      decorations.clear();
      for (const disposable of disposables) disposable.dispose();
    },
  };
}
