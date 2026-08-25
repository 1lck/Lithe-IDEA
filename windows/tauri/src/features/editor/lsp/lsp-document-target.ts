import { getBufferByPath } from "@/features/editor/utils/buffer-index";
import type { EditorContent, PaneContent } from "@/features/panes/types/pane-content.types";
import {
  isEditorLspSupported,
  languageIdForEditorFile,
} from "./built-in-language-support";

export interface LspDocumentTarget {
  filePath: string;
  documentUri?: string;
  sessionFilePath?: string;
  languageId?: string;
}

export type LspDocumentTargetInput = string | LspDocumentTarget;

type EditorLspDocumentSource = Pick<
  EditorContent,
  "path" | "language" | "languageOverride" | "lspDocument"
>;

export function normalizeLspDocumentTarget(target: LspDocumentTargetInput): LspDocumentTarget {
  return typeof target === "string" ? { filePath: target } : target;
}

export function lspDocumentTargetForEditor(buffer: EditorLspDocumentSource): LspDocumentTarget {
  return {
    filePath: buffer.path,
    documentUri: buffer.lspDocument?.documentUri,
    sessionFilePath: buffer.lspDocument?.sessionFilePath,
    languageId:
      buffer.languageOverride ??
      buffer.lspDocument?.languageId ??
      buffer.language ??
      languageIdForEditorFile(buffer.path),
  };
}

export function lspDocumentTargetForEditorPath(
  buffers: readonly PaneContent[],
  filePath: string,
): LspDocumentTarget | null {
  const buffer = getBufferByPath(buffers, filePath);
  return buffer?.type === "editor" ? lspDocumentTargetForEditor(buffer) : null;
}

export function lspDocumentRequestArgs(target: LspDocumentTargetInput) {
  const document = normalizeLspDocumentTarget(target);
  return {
    filePath: document.filePath,
    sessionFilePath: document.sessionFilePath,
    documentUri: document.documentUri,
  };
}

export function lspSessionFilePath(target: LspDocumentTargetInput): string {
  const document = normalizeLspDocumentTarget(target);
  return document.sessionFilePath ?? document.filePath;
}

export function isEditorLspTargetSupported(target: LspDocumentTargetInput): boolean {
  return isEditorLspSupported(lspSessionFilePath(target));
}
