import type { EditorTextChange } from "../types/editor.types";

type DocumentChangeListener = (filePath: string) => void;
type DocumentChangeFlusher = () => Promise<void>;

const pendingChanges = new Map<string, EditorTextChange[]>();
const listeners = new Set<DocumentChangeListener>();
const flushers = new Map<string, DocumentChangeFlusher>();

export function queueLspDocumentChanges(filePath: string, changes: readonly EditorTextChange[]): void {
  if (!filePath || changes.length === 0) return;
  const queued = pendingChanges.get(filePath) ?? [];
  queued.push(...changes);
  pendingChanges.set(filePath, queued);
  for (const listener of listeners) listener(filePath);
}

export function takeLspDocumentChanges(filePath: string): EditorTextChange[] {
  const queued = pendingChanges.get(filePath) ?? [];
  pendingChanges.delete(filePath);
  return queued;
}

export function hasLspDocumentChanges(filePath: string): boolean {
  return (pendingChanges.get(filePath)?.length ?? 0) > 0;
}

export function subscribeLspDocumentChanges(listener: DocumentChangeListener): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

/**
 * Registers the owner that can send `filePath`'s queued changes without waiting
 * for the debounce timer, and returns the matching unregister function.
 */
export function registerLspDocumentChangeFlusher(
  filePath: string,
  flusher: DocumentChangeFlusher,
): () => void {
  flushers.set(filePath, flusher);
  return () => {
    if (flushers.get(filePath) === flusher) {
      flushers.delete(filePath);
    }
  };
}

/**
 * Delivers queued changes for `filePath` before a position-carrying request is
 * sent.
 *
 * Completion is requested from the keystroke that produced the change, while the
 * change itself waits out the document-change debounce. Without this the server
 * answers from the document it already has, so the cursor sits one character
 * ahead of what it knows and it returns nothing. Resolves once the changes are
 * on their way, and is a no-op for files without an owner or pending changes.
 */
export async function flushLspDocumentChanges(filePath: string): Promise<void> {
  await flushers.get(filePath)?.();
}
