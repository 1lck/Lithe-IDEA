import { editor as monacoEditor, Range as MonacoRange } from "monaco-editor";
import type * as Monaco from "monaco-editor";
import type { DefinitionNavigationHint } from "@/features/editor/lsp/definition-navigation-hint";
import type { WorkspaceLaunchScope } from "@/features/workspace/types/workspace-launch-scope";
import {
  isEditorLspTargetSupported,
  type LspDocumentTarget,
} from "@/features/editor/lsp/lsp-document-target";
import {
  isDocumentFeatureAvailable,
  LspClient,
  type LspLocation,
} from "@/features/editor/lsp/lsp-client";
import { resolveLombokAccessorDefinition } from "@/features/editor/lsp/lombok-accessor-navigation";
import { logger } from "@/features/editor/utils/logger";
import {
  isEditorGoToDefinitionModifierActive,
  isEditorGoToDefinitionModifierKey,
} from "@/features/editor/utils/go-to-definition-gesture";
import { frontendTrace } from "@/utils/frontend-trace";
import { DefinitionHoverScheduler } from "./definition-link-scheduler";

const DEFINITION_HOVER_DELAY_MILLISECONDS = 150;

interface MonacoDefinitionLinkOptions {
  editor: Monaco.editor.IStandaloneCodeEditor;
  model: Monaco.editor.ITextModel;
  documentTarget: LspDocumentTarget;
  workspaceScope?: WorkspaceLaunchScope;
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
  workspaceScope,
  enabled = true,
}: MonacoDefinitionLinkOptions): MonacoDefinitionLinkGesture {
  const decorations = editor.createDecorationsCollection();
  const lspSupported = isEditorLspTargetSupported(documentTarget);
  const gestureEnabled = enabled && Boolean(documentTarget.filePath) && lspSupported;
  const isVirtualDocument = Boolean(documentTarget.documentUri);
  let hoveredPosition: Monaco.Position | null = null;
  let modifierTraceState: "idle" | "active" | "missing-target" = "idle";

  if (isVirtualDocument) {
    frontendTrace("info", "definition-link", "registered", {
      enabled: gestureEnabled,
      requested_enabled: enabled,
      lsp_supported: lspSupported,
      language_id: model.getLanguageId(),
      has_session_file_path: Boolean(documentTarget.sessionFilePath),
    });
  }

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
    onActiveRequest: (request) => {
      // IDEA exposes link affordance immediately. Semantic resolution remains
      // authoritative for click navigation and removes false candidates later.
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
    resolve: async (request) => {
      const line = request.lineNumber - 1;
      if (isVirtualDocument) {
        frontendTrace("info", "definition-link", "resolve:start", {
          language_id: model.getLanguageId(),
        });
      }
      const lspClient = LspClient.getInstance();
      if (
        workspaceScope &&
        !isDocumentFeatureAvailable(
          lspClient.getDocumentAvailability(documentTarget, "definition"),
        )
      ) {
        try {
          await lspClient.ensureDocumentReady(
            documentTarget,
            workspaceScope,
            model.getValue(),
            "definition",
          );
        } catch (error) {
          logger.error("DefinitionLink", "Could not prepare definition session:", error);
          return { locations: [] };
        }
      }
      const locations =
        (await lspClient.getDefinition(documentTarget, line, request.character)) ?? [];
      if (isVirtualDocument) {
        frontendTrace("info", "definition-link", "resolve:end", {
          location_count: locations.length,
        });
      }
      if (
        locations.length > 0 ||
        model.isDisposed() ||
        model.getLanguageId() !== "java" ||
        documentTarget.documentUri ||
        !workspaceScope
      ) {
        return { locations };
      }

      try {
        const lombokDefinition = await resolveLombokAccessorDefinition({
          source: model.getValue(),
          sourceFilePath: documentTarget.filePath,
          workspaceRoot: workspaceScope.root,
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
      if (isVirtualDocument) {
        frontendTrace("info", "definition-link", "decoration:set", {
          location_count: result.locations.length,
        });
      }
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
    scheduler.activate(request);
  };

  const syncLinkForModifier = (event: {
    ctrlKey?: boolean;
    metaKey?: boolean;
    altKey?: boolean;
    shiftKey?: boolean;
  }) => {
    if (hoveredPosition && isEditorGoToDefinitionModifierActive(event)) {
      if (isVirtualDocument && modifierTraceState !== "active") {
        modifierTraceState = "active";
        frontendTrace("info", "definition-link", "modifier:active");
      }
      showLink(hoveredPosition);
    } else {
      if (
        isVirtualDocument &&
        !hoveredPosition &&
        isEditorGoToDefinitionModifierActive(event) &&
        modifierTraceState !== "missing-target"
      ) {
        modifierTraceState = "missing-target";
        frontendTrace("info", "definition-link", "modifier:missing-target");
      } else if (!isEditorGoToDefinitionModifierActive(event)) {
        modifierTraceState = "idle";
      }
      clearLink();
    }
  };

  const handleWindowModifierKey = (event: KeyboardEvent) => {
    if (!isEditorGoToDefinitionModifierKey(event)) return;
    syncLinkForModifier(event);
  };

  if (gestureEnabled) {
    window.addEventListener("keydown", handleWindowModifierKey, true);
    window.addEventListener("keyup", handleWindowModifierKey, true);
  }

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
        {
          dispose() {
            window.removeEventListener("keydown", handleWindowModifierKey, true);
            window.removeEventListener("keyup", handleWindowModifierKey, true);
          },
        },
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
