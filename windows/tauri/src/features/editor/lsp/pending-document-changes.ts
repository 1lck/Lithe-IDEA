import type { EditorTextChange } from "../types/editor.types";

type DocumentChangeListener = (filePath: string) => void;

const pendingChanges = new Map<string, EditorTextChange[]>();
const listeners = new Set<DocumentChangeListener>();

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
