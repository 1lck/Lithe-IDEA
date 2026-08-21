import type {
  EditorLspDocumentBinding,
  PaneContent,
} from "@/features/panes/types/pane-content.types";
import { getBufferById } from "@/features/editor/utils/buffer-index";

export interface EditorBufferSurface {
  id: string;
  path: string;
  type: PaneContent["type"];
  isPreview: boolean;
  isVirtual: boolean;
  language?: string;
  languageOverride?: string;
  lspDocument?: EditorLspDocumentBinding;
  contentRevision: number;
}

export function getBufferContentRevision(buffer: PaneContent | null | undefined): number {
  if (!buffer) return 0;
  if (buffer.type === "editor" || buffer.type === "diff") {
    return buffer.contentRevision ?? 0;
  }
  return 0;
}

export function getEditorBufferSurface(
  buffer: PaneContent | null | undefined,
): EditorBufferSurface | null {
  if (!buffer) return null;
  return {
    id: buffer.id,
    path: buffer.path,
    type: buffer.type,
    isPreview: buffer.isPreview,
    isVirtual: buffer.type === "editor" ? buffer.isVirtual : false,
    language: buffer.type === "editor" ? buffer.language : undefined,
    languageOverride: buffer.type === "editor" ? buffer.languageOverride : undefined,
    lspDocument: buffer.type === "editor" ? buffer.lspDocument : undefined,
    contentRevision: getBufferContentRevision(buffer),
  };
}

export function selectEditorBufferSurface(
  buffers: readonly PaneContent[],
  bufferId: string | null | undefined,
): EditorBufferSurface | null {
  return getEditorBufferSurface(getBufferById(buffers, bufferId));
}

export function editorBufferSurfacesEqual(
  left: EditorBufferSurface | null,
  right: EditorBufferSurface | null,
): boolean {
  if (left === right) return true;
  if (!left || !right) return false;
  return (
    left.id === right.id &&
    left.path === right.path &&
    left.type === right.type &&
    left.isPreview === right.isPreview &&
    left.isVirtual === right.isVirtual &&
    left.language === right.language &&
    left.languageOverride === right.languageOverride &&
    left.lspDocument?.documentUri === right.lspDocument?.documentUri &&
    left.lspDocument?.sessionFilePath === right.lspDocument?.sessionFilePath &&
    left.lspDocument?.languageId === right.lspDocument?.languageId &&
    left.contentRevision === right.contentRevision
  );
}
