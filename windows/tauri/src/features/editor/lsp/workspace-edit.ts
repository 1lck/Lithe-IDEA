import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { createTranslator } from "@/i18n/locale";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
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
  const result = await invoke<{ text: string; editError?: { code: string; details?: string } }>("lsp.applyTextEdits", {
    text: content,
    edits: edits.map((edit) => ({
      range: {
        start: { line: edit.range.start.line, utf16Column: edit.range.start.character },
        end: { line: edit.range.end.line, utf16Column: edit.range.end.character },
      },
      newText: edit.newText,
    })),
  });
  if (result.editError) {
    const t = createTranslator(useSettingsStore.getState().settings.displayLanguage);
    const key = result.editError.details === "overlappingEdits" ? "native.languageServerReturnedOverlappingTextEdits" : "native.languageServerReturnedAnInvalidTextRange";
    throw Object.assign(new Error(t(key)), { code: result.editError.code, details: result.editError.details });
  }
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

export async function applyWorkspaceEdit(edit: WorkspaceEdit): Promise<WorkspaceEditApplyResult> {
  const workspaceId = workspaceRuntimeRegistry.getActiveWorkspaceId();
  const [{ useBufferStore }, { trackImmediateBufferHistoryChange }, { readFile, writeFile }] = await Promise.all([
    import("../stores/buffer.store"), import("../stores/buffer-history-tracking"), import("@/features/file-system/controllers/platform"),
  ]);
  const store = useBufferStore.getStore(workspaceId);
  const editsByFile = collectWorkspaceTextEdits(edit);
  const prepared = await Promise.all(Array.from(editsByFile, async ([filePath, edits]) => {
    const buffer = store.getState().buffers.find((entry) => entry.type === "editor" && !entry.isVirtual && entry.path === filePath);
    if (buffer?.type === "editor") requireLoadedBufferContent(buffer);
    const content = buffer?.type === "editor" ? buffer.content : await readFile(filePath);
    const revision = buffer?.type === "editor" ? buffer.contentRevision : undefined;
    const nextContent = await applyTextEditsToContent(content, edits);
    return { filePath, bufferId: buffer?.id, content, revision, nextContent };
  }));
  const stale = () => new Error(createTranslator(useSettingsStore.getState().settings.displayLanguage)("editor.workspaceEditStale"));
  if (workspaceRuntimeRegistry.getActiveWorkspaceId() !== workspaceId || useBufferStore.getStore(workspaceId) !== store) throw stale();
  // Check every prepared target before any buffer is changed. No await occurs
  // between this barrier and the in-memory writes, so user input cannot interleave.
  for (const source of prepared) {
    const buffer = store.getState().buffers.find((entry) => entry.type === "editor" && !entry.isVirtual && entry.path === source.filePath);
    if (source.bufferId ? (!buffer || buffer.type !== "editor" || buffer.id !== source.bufferId || buffer.content !== source.content || buffer.contentRevision !== source.revision) : !!buffer) throw stale();
  }
  const diskWrites: Promise<unknown>[] = [];
  for (const source of prepared) {
    if (source.bufferId) {
      trackImmediateBufferHistoryChange({ bufferId: source.bufferId, currentContent: source.content, nextContent: source.nextContent });
      store.getState().actions.updateBufferContent(source.bufferId, source.nextContent, true);
    } else {
      diskWrites.push(writeFile(source.filePath, source.nextContent));
    }
  }
  await Promise.all(diskWrites);
  return { editedFiles: editsByFile.size };
}
