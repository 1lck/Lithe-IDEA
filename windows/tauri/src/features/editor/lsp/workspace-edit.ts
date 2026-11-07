import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { createTranslator } from "@/i18n/locale";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { invoke } from "@/platform/tauri-core";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { getNativeWorkspaceRootPaths } from "@/features/file-search/utils/file-search-paths";
import { closestWorkspaceRoot } from "@/features/workspace/types/workspace-root";
import { getBufferByPath } from "../utils/buffer-index";
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

interface PlannedTarget {
  path: string;
  effect: "writeFile" | "updateDocument";
  edits: LspTextEdit[];
}

interface WorkspaceEditPlan {
  rejection: { code: "outsideWorkspace" | "readOnlyDocument"; path: string } | null;
  targets: PlannedTarget[];
}

/**
 * Asks Core (`lsp.planWorkspaceEdit`) whether every target may be edited and in
 * which order they commit: closed files first, then open documents. Targets are
 * grouped by the workspace root that contains them, so a multi-root workspace
 * keeps working while a file outside every root is refused.
 */
async function planWorkspaceEdit(
  editsByFile: Map<string, LspTextEdit[]>,
  openDocuments: Array<{ path: string; isReadOnly: boolean }>,
  translate: ReturnType<typeof createTranslator>,
): Promise<PlannedTarget[]> {
  const state = useFileSystemStore.getStore(workspaceRuntimeRegistry.getActiveWorkspaceId()).getState();
  const roots = getNativeWorkspaceRootPaths(state.rootFolderPath, state.workspaceFolders);
  const groups = new Map<string, Record<string, LspTextEdit[]>>();
  for (const [filePath, edits] of editsByFile) {
    const root = closestWorkspaceRoot(filePath, roots) ?? state.rootFolderPath ?? undefined;
    if (!root) throw new Error(translate("editor.workspaceEditOutsideWorkspace"));
    groups.set(root, { ...groups.get(root), [filePath]: edits });
  }
  const targets: PlannedTarget[] = [];
  for (const [workspaceRoot, changes] of groups) {
    const plan = await invoke<WorkspaceEditPlan>("lsp.planWorkspaceEdit", {
      platform: "windows",
      workspaceRoot,
      changes,
      openDocuments,
    });
    if (plan.rejection) {
      throw new Error(translate(plan.rejection.code === "readOnlyDocument"
        ? "editor.workspaceEditReadOnlyDocument"
        : "editor.workspaceEditOutsideWorkspace"));
    }
    targets.push(...plan.targets);
  }
  return targets;
}

export async function applyWorkspaceEdit(edit: WorkspaceEdit): Promise<WorkspaceEditApplyResult> {
  const workspaceId = workspaceRuntimeRegistry.getActiveWorkspaceId();
  const [{ useBufferStore }, { trackImmediateBufferHistoryChange }, { readFile, writeFile }] = await Promise.all([
    import("../stores/buffer.store"), import("../stores/buffer-history-tracking"), import("@/features/file-system/controllers/platform"),
  ]);
  const store = useBufferStore.getStore(workspaceId);
  const translate = createTranslator(useSettingsStore.getState().settings.displayLanguage);
  const openEditors = () => store.getState().buffers.filter((entry) => entry.type === "editor" && !entry.isVirtual);
  const bufferFor = (filePath: string) => getBufferByPath(openEditors(), filePath);
  const targets = await planWorkspaceEdit(
    collectWorkspaceTextEdits(edit),
    openEditors().map((entry) => ({ path: entry.path, isReadOnly: entry.type === "editor" && !!entry.readOnly })),
    translate,
  );
  const prepared = await Promise.all(targets.map(async (target) => {
    const buffer = target.effect === "updateDocument" ? bufferFor(target.path) : undefined;
    if (buffer?.type === "editor") requireLoadedBufferContent(buffer);
    const content = buffer?.type === "editor" ? buffer.content : await readFile(target.path);
    const revision = buffer?.type === "editor" ? buffer.contentRevision : undefined;
    const nextContent = await applyTextEditsToContent(content, target.edits);
    return { filePath: target.path, bufferId: buffer?.id, content, revision, nextContent };
  }));
  const stale = () => new Error(translate("editor.workspaceEditStale"));
  // Every prepared target must still match what the edits were computed from.
  const verifyUnchanged = () => {
    if (workspaceRuntimeRegistry.getActiveWorkspaceId() !== workspaceId || useBufferStore.getStore(workspaceId) !== store) throw stale();
    for (const source of prepared) {
      const buffer = bufferFor(source.filePath);
      if (source.bufferId ? (!buffer || buffer.type !== "editor" || buffer.id !== source.bufferId || buffer.content !== source.content || buffer.contentRevision !== source.revision) : !!buffer) throw stale();
    }
  };
  verifyUnchanged();
  // Closed files are written first, sequentially, so a failure can restore the
  // ones already written and leave the workspace as it was.
  const written: typeof prepared = [];
  const rollback = async (cause: unknown): Promise<never> => {
    const failed: string[] = [];
    for (const source of written.reverse()) {
      try { await writeFile(source.filePath, source.content); } catch { failed.push(source.filePath); }
    }
    if (failed.length === 0) throw cause;
    throw Object.assign(new Error(translate("editor.workspaceEditRollbackFailed", { paths: failed.join(", ") })), { cause });
  };
  try {
    for (const source of prepared) {
      if (source.bufferId) continue;
      written.push(source);
      await writeFile(source.filePath, source.nextContent);
    }
    // Input may have arrived while the files were written; nothing in memory has changed yet.
    verifyUnchanged();
  } catch (error) {
    return rollback(error);
  }
  // No await occurs between this point and the in-memory writes, so user input cannot interleave.
  for (const source of prepared) {
    if (!source.bufferId) continue;
    trackImmediateBufferHistoryChange({ bufferId: source.bufferId, currentContent: source.content, nextContent: source.nextContent });
    store.getState().actions.updateBufferContent(source.bufferId, source.nextContent, true);
  }
  return { editedFiles: prepared.length };
}
