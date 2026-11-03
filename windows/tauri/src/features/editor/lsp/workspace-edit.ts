import { invoke } from "@/platform/tauri-core";
import { requireLoadedBufferContent } from "../utils/buffer-load-state";

export interface LspPosition {
  line: number;
  character: number;
}

export interface LspTextEdit {
  range: {
    start: LspPosition;
    end: LspPosition;
  };
  newText: string;
}

interface TextDocumentEdit {
  textDocument: {
    uri: string;
  };
  edits: LspTextEdit[];
}

export interface WorkspaceEdit {
  changes?: Record<string, LspTextEdit[]>;
  documentChanges?: Array<TextDocumentEdit | unknown>;
}

export interface WorkspaceEditApplyResult {
  editedFiles: number;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function isTextEdit(value: unknown): value is LspTextEdit {
  return (
    isObject(value) &&
    isObject(value.range) &&
    isObject(value.range.start) &&
    typeof value.range.start.line === "number" &&
    typeof value.range.start.character === "number" &&
    isObject(value.range.end) &&
    typeof value.range.end.line === "number" &&
    typeof value.range.end.character === "number" &&
    typeof value.newText === "string"
  );
}

function isTextDocumentEdit(value: unknown): value is TextDocumentEdit {
  return (
    isObject(value) &&
    isObject(value.textDocument) &&
    typeof value.textDocument.uri === "string" &&
    Array.isArray(value.edits) &&
    value.edits.every(isTextEdit)
  );
}

export function isWorkspaceEdit(value: unknown): value is WorkspaceEdit {
  if (!isObject(value)) return false;

  const hasChanges =
    isObject(value.changes) &&
    Object.values(value.changes).every((edits) => Array.isArray(edits) && edits.every(isTextEdit));
  const hasDocumentChanges =
    Array.isArray(value.documentChanges) && value.documentChanges.some(isTextDocumentEdit);

  return hasChanges || hasDocumentChanges;
}

function decodeUriPath(path: string): string {
  try {
    return decodeURIComponent(path);
  } catch {
    return path;
  }
}

export function filePathFromUri(uri: string): string {
  if (!uri.startsWith("file://")) return uri;

  try {
    const url = new URL(uri);
    const pathname = decodeUriPath(url.pathname);
    // URL.pathname keeps the leading slash in `file:///C:/...`; remove it so
    // Windows hosts receive a drive-qualified path instead of `/C:/...`.
    if (/^\/[A-Za-z]:\//.test(pathname)) return pathname.slice(1);
    if (url.hostname) return `//${url.hostname}${pathname}`;
    return pathname;
  } catch {
    const path = decodeUriPath(uri.replace(/^file:\/\//, ""));
    return path.replace(/^\/([A-Za-z]:[\\/])/, "$1");
  }
}

// Core owns range validation, UTF-16 offsets, overlap detection and edit order.
export async function applyTextEditsToContent(content: string, edits: LspTextEdit[]): Promise<string> {
  const result = await invoke<{ text: string }>("lsp.applyTextEdits", {
    text: content,
    edits: edits.map((edit) => ({
      range: {
        start: { line: edit.range.start.line, utf16Column: edit.range.start.character },
        end: { line: edit.range.end.line, utf16Column: edit.range.end.character },
      },
      newText: edit.newText,
    })),
  });
  return result.text;
}

export function collectWorkspaceTextEdits(edit: WorkspaceEdit): Map<string, LspTextEdit[]> {
  const editsByFile = new Map<string, LspTextEdit[]>();

  for (const [uri, edits] of Object.entries(edit.changes ?? {})) {
    editsByFile.set(filePathFromUri(uri), [...edits]);
  }

  for (const documentChange of edit.documentChanges ?? []) {
    if (!isTextDocumentEdit(documentChange)) continue;

    const filePath = filePathFromUri(documentChange.textDocument.uri);
    const existing = editsByFile.get(filePath) ?? [];
    editsByFile.set(filePath, [...existing, ...documentChange.edits]);
  }

  return editsByFile;
}

async function readEditableSource(
  filePath: string,
): Promise<{ bufferId: string | null; content: string }> {
  const { useBufferStore } = await import("../stores/buffer.store");
  const { readFile } = await import("@/features/file-system/controllers/platform");
  const { buffers } = useBufferStore.getState();
  const openBuffer = buffers.find(
    (buffer) => buffer.type === "editor" && !buffer.isVirtual && buffer.path === filePath,
  );

  if (openBuffer?.type === "editor") {
    requireLoadedBufferContent(openBuffer);
    return { bufferId: openBuffer.id, content: openBuffer.content };
  }

  return { bufferId: null, content: await readFile(filePath) };
}

async function writeEditableSource(filePath: string, bufferId: string | null, content: string) {
  const { useBufferStore } = await import("../stores/buffer.store");
  const { trackImmediateBufferHistoryChange } = await import("../stores/buffer-history-tracking");
  const { writeFile } = await import("@/features/file-system/controllers/platform");

  if (bufferId) {
    const buffer = useBufferStore.getState().buffers.find((candidate) => candidate.id === bufferId);
    if (buffer?.type === "editor") {
      trackImmediateBufferHistoryChange({
        bufferId,
        currentContent: buffer.content,
        nextContent: content,
      });
    }
    useBufferStore.getState().actions.updateBufferContent(bufferId, content, true);
    return;
  }

  await writeFile(filePath, content);
}

export async function applyWorkspaceEdit(edit: WorkspaceEdit): Promise<WorkspaceEditApplyResult> {
  const editsByFile = collectWorkspaceTextEdits(edit);

  // Validate/read every target before applying any edit. A restoring tab must
  // not cause a rename to partially modify the other documents.
  const prepared = await Promise.all(
    Array.from(editsByFile, async ([filePath, edits]) => {
      const source = await readEditableSource(filePath);
      const nextContent = await applyTextEditsToContent(source.content, edits);
      return { filePath, bufferId: source.bufferId, nextContent };
    }),
  );
  await Promise.all(
    prepared.map(({ filePath, bufferId, nextContent }) =>
      writeEditableSource(filePath, bufferId, nextContent)),
  );

  return { editedFiles: editsByFile.size };
}
