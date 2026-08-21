import type { PaneContent } from "@/features/panes/types/pane-content.types";
import { getBufferById } from "@/features/editor/utils/buffer-index";

export interface EditorBufferSurface {
  id: string;
  path: string;
  type: PaneContent["type"];
  isPreview: boolean;
  isVirtual: boolean;
  languageOverride?: string;
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
    languageOverride: buffer.type === "editor" ? buffer.languageOverride : undefined,
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
    left.languageOverride === right.languageOverride &&
    left.contentRevision === right.contentRevision
  );
}
