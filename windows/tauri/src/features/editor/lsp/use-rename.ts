import { useCallback, useEffect, useRef, useState } from "react";
import { editorAPI } from "@/features/editor/extensions/api";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { useEditorStateStore } from "@/features/editor/stores/state.store";
import { getLineTextFromContent } from "@/features/editor/utils/position";
import { lspDocumentTargetForEditorPath } from "./lsp-document-target";
import { LspClient } from "./lsp-client";
import { applyWorkspaceEdit, isWorkspaceEdit } from "./workspace-edit";
import { logger } from "../utils/logger";

interface RenameState {
  isVisible: boolean;
  symbol: string;
  line: number;
  column: number;
}

function getWordUnderCursor(line: string, column: number): string {
  const before = line.slice(0, column + 1).match(/[\w$]+$/);
  const after = line.slice(column).match(/^[\w$]*/);
  return (before?.[0] || "") + (after?.[0]?.slice(1) || "");
}

export const useRename = (filePath: string | undefined) => {
  const [renameState, setRenameState] = useState<RenameState | null>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  const startRename = useCallback(async () => {
    if (!filePath) return;

    const cursorPosition = useEditorStateStore.getState().cursorPosition;
    const content = editorAPI.getContent();
    const currentLine = getLineTextFromContent(content, cursorPosition.line);
    const lspClient = LspClient.getInstance();
    const target = lspDocumentTargetForEditorPath(useBufferStore.getState().buffers, filePath);
    if (!target || !lspClient.getDocumentAvailability(target, "rename").available) return;
    const symbol = getWordUnderCursor(currentLine, cursorPosition.column);

    if (!symbol) return;

    setRenameState({
      isVisible: true,
      symbol,
      line: cursorPosition.line,
      column: cursorPosition.column,
    });

    // Focus input on next tick
    setTimeout(() => {
      inputRef.current?.focus();
      inputRef.current?.select();
    }, 0);
  }, [filePath]);

  const cancelRename = useCallback(() => {
    setRenameState(null);
  }, []);

  const executeRename = useCallback(
    async (newName: string) => {
      if (!filePath || !renameState) return;

      const trimmed = newName.trim();
      if (!trimmed || trimmed === renameState.symbol) {
        cancelRename();
        return;
      }

      setRenameState(null);

      try {
        const lspClient = LspClient.getInstance();
        const target = lspDocumentTargetForEditorPath(useBufferStore.getState().buffers, filePath);
        if (!target || !lspClient.getDocumentAvailability(target, "rename").available) return;
        const result = await lspClient.rename(
          target,
          renameState.line,
          renameState.column,
          trimmed,
        );

        if (!isWorkspaceEdit(result)) {
          logger.debug("Rename", "No changes returned from LSP");
          return;
        }

        const { editedFiles } = await applyWorkspaceEdit(result);

        logger.info(
          "Rename",
          `Renamed "${renameState.symbol}" to "${trimmed}" across ${editedFiles} file(s)`,
        );
      } catch (error) {
        logger.error("Rename", "Failed to execute rename:", error);
      }
    },
    [filePath, renameState, cancelRename],
  );

  // Listen for rename event
  useEffect(() => {
    const handler = () => void startRename();
    window.addEventListener("editor-rename-symbol", handler);
    return () => window.removeEventListener("editor-rename-symbol", handler);
  }, [startRename]);

  return {
    renameState,
    inputRef,
    cancelRename,
    executeRename,
  };
};
