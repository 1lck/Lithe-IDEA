import { editor as monacoEditor, Range as MonacoRange } from "monaco-editor";
import type * as Monaco from "monaco-editor";
import { isEditorLspSupported } from "@/features/editor/lsp/built-in-language-support";
import { LspClient } from "@/features/editor/lsp/lsp-client";
import { resolveLombokAccessorDefinition } from "@/features/editor/lsp/lombok-accessor-navigation";
import { logger } from "@/features/editor/utils/logger";
import { isEditorGoToDefinitionModifierActive } from "@/features/editor/utils/go-to-definition-gesture";

interface MonacoDefinitionLinkOptions {
  editor: Monaco.editor.IStandaloneCodeEditor;
  model: Monaco.editor.ITextModel;
  filePath: string;
  workspaceRoot?: string;
}

export function registerMonacoDefinitionLinkGesture({
  editor,
  model,
  filePath,
  workspaceRoot,
}: MonacoDefinitionLinkOptions): Monaco.IDisposable {
  const decorations = editor.createDecorationsCollection();
  let requestVersion = 0;
  let hoveredPosition: Monaco.Position | null = null;
  let resolvedWordKey = "";

  const clearLink = () => {
    if (!resolvedWordKey && decorations.length === 0) return;
    requestVersion += 1;
    resolvedWordKey = "";
    decorations.clear();
  };

  const showLink = async (position: Monaco.Position) => {
    if (!filePath || !isEditorLspSupported(filePath)) {
      clearLink();
      return;
    }

    const word = model.getWordAtPosition(position);
    if (!word) {
      clearLink();
      return;
    }

    const wordKey = `${position.lineNumber}:${word.startColumn}:${word.endColumn}`;
    if (resolvedWordKey === wordKey) return;
    resolvedWordKey = wordKey;
    decorations.clear();
    const request = ++requestVersion;

    try {
      const line = position.lineNumber - 1;
      const character = position.column - 1;
      const locations = await LspClient.getInstance().getDefinition(filePath, line, character);
      const lombokDefinition =
        (!locations || locations.length === 0) && model.getLanguageId() === "java" && workspaceRoot
          ? await resolveLombokAccessorDefinition({
              source: model.getValue(),
              sourceFilePath: filePath,
              workspaceRoot,
              line,
              character,
            })
          : null;
      if (request !== requestVersion || model.isDisposed()) return;
      if ((!locations || locations.length === 0) && !lombokDefinition) return;

      decorations.set([
        {
          range: new MonacoRange(
            position.lineNumber,
            word.startColumn,
            position.lineNumber,
            word.endColumn,
          ),
          options: { inlineClassName: "goto-definition-link" },
        },
      ]);
    } catch (error) {
      if (request !== requestVersion) return;
      logger.error("DefinitionLink", "Could not resolve definition link:", error);
    }
  };

  const syncLinkForModifier = (event: {
    ctrlKey?: boolean;
    metaKey?: boolean;
    altKey?: boolean;
    shiftKey?: boolean;
  }) => {
    if (hoveredPosition && isEditorGoToDefinitionModifierActive(event)) {
      void showLink(hoveredPosition);
    } else {
      clearLink();
    }
  };

  const disposables = [
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
    editor.onDidChangeModelContent(clearLink),
    editor.onDidBlurEditorWidget(clearLink),
  ];

  return {
    dispose() {
      requestVersion += 1;
      decorations.clear();
      for (const disposable of disposables) disposable.dispose();
    },
  };
}
