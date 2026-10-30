import type { EditorContent, PaneContent } from "@/features/panes/types/pane-content.types";
import { isBufferContentLoaded } from "./buffer-load-state";

/**
 * Workspace indexes (Spring, MyBatis) read files from disk in Core. An editor
 * buffer only changes their result while its text differs from disk, so
 * opening, saving, or closing a clean file must not trigger a workspace rescan.
 */
function indexedEditorBuffer(
  buffer: PaneContent,
  isIndexPath: (path: string) => boolean,
): EditorContent | null {
  if (buffer.type !== "editor" || buffer.isVirtual || !buffer.path) return null;
  if (!isBufferContentLoaded(buffer) || !isIndexPath(buffer.path)) return null;
  return buffer;
}

function isUnsaved(buffer: EditorContent): boolean {
  return buffer.content !== buffer.savedContent;
}

/** Unsaved text keyed by workspace-relative path; clean buffers are read from disk. */
export function collectUnsavedIndexTextOverrides(
  buffers: readonly PaneContent[],
  isIndexPath: (path: string) => boolean,
  relativePath: (path: string) => string,
): Record<string, string> {
  const overrides: Record<string, string> = {};
  for (const candidate of buffers) {
    const buffer = indexedEditorBuffer(candidate, isIndexPath);
    if (!buffer || !isUnsaved(buffer)) continue;
    const relative = relativePath(buffer.path);
    if (relative) overrides[relative] = buffer.content;
  }
  return overrides;
}

function indexedBuffersByPath(
  buffers: readonly PaneContent[],
  isIndexPath: (path: string) => boolean,
): Map<string, EditorContent> {
  const byPath = new Map<string, EditorContent>();
  for (const candidate of buffers) {
    const buffer = indexedEditorBuffer(candidate, isIndexPath);
    if (buffer) byPath.set(buffer.path, buffer);
  }
  return byPath;
}

/**
 * Whether the text a workspace index should see changed between two buffer
 * snapshots. A buffer that appears or disappears matters only when it held
 * unsaved text; a buffer present in both matters when its text changed.
 */
export function didIndexedEditorTextChange(
  buffers: readonly PaneContent[],
  previousBuffers: readonly PaneContent[],
  isIndexPath: (path: string) => boolean,
): boolean {
  if (buffers === previousBuffers) return false;
  const current = indexedBuffersByPath(buffers, isIndexPath);
  const previous = indexedBuffersByPath(previousBuffers, isIndexPath);
  for (const [path, buffer] of current) {
    const before = previous.get(path);
    if (before ? before.content !== buffer.content : isUnsaved(buffer)) return true;
  }
  for (const [path, before] of previous) {
    if (!current.has(path) && isUnsaved(before)) return true;
  }
  return false;
}
