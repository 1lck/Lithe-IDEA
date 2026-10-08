import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { bufferNotLoadedMessage, isBufferContentLoaded } from "../utils/buffer-load-state";
import { isLocalDocumentPath, readDocumentFile, saveDocumentFile } from "@/platform/document-files";
import type { FileEncoding } from "@/platform/document-files";
import { decideDocumentLifecycle } from "@/platform/document-lifecycle";
import { invoke } from "@/platform/tauri-core";
import { toast } from "sonner";
import { immer } from "zustand/middleware/immer";
import { createStore } from "zustand/vanilla";
import { extensionRegistry } from "@/extensions/registry/extension-registry";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { emitGitChanged } from "@/features/git/events/git-events";
import { recordLocalHistoryFile } from "@/features/local-history/api/local-history-api";
import {
  isEditorContent,
  type EditorContent,
  type PaneContent,
} from "@/features/panes/types/pane-content.types";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { createWorkspaceScopedStore } from "@/features/workspace/stores/create-workspace-scoped-store";
import { createTranslator } from "@/i18n/locale";
import { createSelectors } from "@/utils/zustand-selectors";
import { writeFile } from "@/features/file-system/controllers/platform";
import {
  beginDocumentSave,
  completeDocumentSave,
  failDocumentSave,
  mergeGrantedDocumentSave,
  mergeTerminalDocumentSave,
  traceDocumentSaveCancellation,
  traceDocumentSaveFailure,
  type DocumentSaveContext,
} from "@/features/editor/services/document-save-lifecycle";
import { restoreDocumentLifecycle } from "@/platform/document-lifecycle";
import type { EditorContentChangeOptions, Position, Range } from "../types/editor.types";
import { getBufferById } from "../utils/buffer-index";
import { trackBufferHistoryChange } from "./buffer-history-tracking";
import { useBufferStore } from "./buffer.store";
import { queueEditorViewContentChange } from "./view.store";

async function recordLocalHistoryBeforeWrite(
  path: string,
  reason: "save" | "auto-save" | "restore",
): Promise<void> {
  try {
    await recordLocalHistoryFile(path, reason);
  } catch (error) {
    console.warn("Failed to record local history:", error);
  }
}

export type EditorSaveResult = "saved" | "cancelled" | "failed";

interface ClaimedDocumentSave {
  context: DocumentSaveContext;
}

async function claimDocumentSave(
  workspaceId: string,
  buffer: EditorContent,
  operationId: string = crypto.randomUUID(),
): Promise<ClaimedDocumentSave | null> {
  const context: DocumentSaveContext = {
    bufferId: buffer.id,
    path: buffer.path,
    operationId,
  };
  const current = restoreDocumentLifecycle(
    buffer.documentLifecycle,
    buffer.contentRevision ?? 0,
    buffer.isDirty,
  );
  const decision = await beginDocumentSave(current, context);
  if (!decision || !workspaceRuntimeRegistry.hasWorkspace(workspaceId)) return null;
  const bufferStore = useBufferStore.getStore(workspaceId);
  const latest = getBufferById(bufferStore.getState().buffers, buffer.id);
  if (!latest || !isEditorContent(latest) || latest.path !== buffer.path ||
      (latest.readEncoding ?? latest.encoding) !== (buffer.readEncoding ?? buffer.encoding)) {
    traceDocumentSaveCancellation(context, "buffer-closed-before-claim");
    return null;
  }
  const saving = mergeGrantedDocumentSave(decision, restoreDocumentLifecycle(
    latest.documentLifecycle, latest.contentRevision ?? 0, latest.isDirty,
  ));
  if (!saving) {
    traceDocumentSaveCancellation(context, "lifecycle-changed-before-claim");
    return null;
  }
  bufferStore.getState().actions.applyDocumentLifecycle(buffer.id, saving);
  return { context };
}

async function persistClaimedDocument(
  workspaceId: string,
  claim: ClaimedDocumentSave,
  content: string,
  expectedContent: string | null,
  targetEncoding?: FileEncoding,
  expectedEncoding?: FileEncoding,
  expectedIdentity?: string,
): Promise<{ saved: boolean; identity?: string }> {
  if (!workspaceRuntimeRegistry.hasWorkspace(workspaceId)) return { saved: false };
  const current = getBufferById(useBufferStore.getStore(workspaceId).getState().buffers, claim.context.bufferId);
  if (!current || !isEditorContent(current) || current.path !== claim.context.path ||
      current.documentLifecycle?.status !== "saving" || current.documentLifecycle.operationId !== claim.context.operationId) return { saved: false };
  if (!isLocalDocumentPath(claim.context.path)) {
    await writeFile(claim.context.path, content);
    return { saved: true };
  }
  const outcome = targetEncoding || expectedEncoding || current.saveEncoding || current.readEncoding || current.encoding
    ? await saveDocumentFile(
        claim.context.path,
        content,
        expectedContent,
        targetEncoding ?? current.saveEncoding ?? current.readEncoding ?? current.encoding ?? "UTF-8",
        expectedEncoding,
        expectedIdentity,
      )
    : await saveDocumentFile(claim.context.path, content, expectedContent);
  if (!workspaceRuntimeRegistry.hasWorkspace(workspaceId)) return { saved: false };
  if (outcome.status === "saved") {
    const latest = getBufferById(useBufferStore.getStore(workspaceId).getState().buffers, claim.context.bufferId);
    if (latest?.type === "editor" && latest.path === claim.context.path &&
        latest.documentLifecycle?.status === "saving" && latest.documentLifecycle.operationId === claim.context.operationId) {
      useBufferStore.getStore(workspaceId).getState().actions.setBufferSaveEncoding(
        latest.id, targetEncoding ?? current.saveEncoding ?? current.readEncoding ?? current.encoding ?? "UTF-8", outcome.identity,
      );
    }
    return { saved: true, identity: outcome.identity };
  }
  const store = useBufferStore.getStore(workspaceId);
  const buffer = getBufferById(store.getState().buffers, claim.context.bufferId);
  if (!buffer || !isEditorContent(buffer) || buffer.path !== claim.context.path) return { saved: false };
  const decision = await decideDocumentLifecycle(restoreDocumentLifecycle(buffer.documentLifecycle, buffer.contentRevision ?? 0, buffer.isDirty), { type: "diskConflict" });
  const latest = getBufferById(store.getState().buffers, claim.context.bufferId);
  if (!latest || !isEditorContent(latest) || latest.path !== claim.context.path) return { saved: false };
  store.getState().actions.updateBuffer({ ...latest, externalDiskContent: outcome.content, externalDiskIdentity: outcome.identity });
  store.getState().actions.applyDocumentLifecycle(latest.id, { ...decision.state, revision: latest.contentRevision ?? 0 });
  return { saved: false };
}

async function finishDocumentSave(
  workspaceId: string,
  claim: ClaimedDocumentSave,
  savedContent: string,
) {
  if (!workspaceRuntimeRegistry.hasWorkspace(workspaceId)) return;
  const bufferStore = useBufferStore.getStore(workspaceId);
  const latest = getBufferById(bufferStore.getState().buffers, claim.context.bufferId);
  if (!latest || !isEditorContent(latest)) return;
  const current = restoreDocumentLifecycle(
    latest.documentLifecycle,
    latest.contentRevision ?? 0,
    latest.isDirty,
  );
  const decision = await completeDocumentSave(current, claim.context);
  const latestAfterDecision = getBufferById(
    bufferStore.getState().buffers,
    claim.context.bufferId,
  );
  if (!latestAfterDecision || !isEditorContent(latestAfterDecision)) return;
  const completed = mergeTerminalDocumentSave(
    decision,
    restoreDocumentLifecycle(
      latestAfterDecision.documentLifecycle,
      latestAfterDecision.contentRevision ?? 0,
      latestAfterDecision.isDirty,
    ),
    claim.context,
    latestAfterDecision.content === savedContent,
  );
  if (!completed) {
    traceDocumentSaveCancellation(claim.context, "stale-success-result");
    return;
  }
  bufferStore
    .getState()
    .actions.recordSuccessfulBufferSave(claim.context.bufferId, savedContent, completed);
}

async function rejectDocumentSave(
  workspaceId: string,
  claim: ClaimedDocumentSave,
  error: unknown,
) {
  if (!workspaceRuntimeRegistry.hasWorkspace(workspaceId)) return;
  const bufferStore = useBufferStore.getStore(workspaceId);
  const latest = getBufferById(bufferStore.getState().buffers, claim.context.bufferId);
  if (!latest || !isEditorContent(latest)) return;
  const current = restoreDocumentLifecycle(
    latest.documentLifecycle,
    latest.contentRevision ?? 0,
    latest.isDirty,
  );
  try {
    const decision = await failDocumentSave(current, claim.context, error);
    const latestAfterDecision = getBufferById(
      bufferStore.getState().buffers,
      claim.context.bufferId,
    );
    if (!latestAfterDecision || !isEditorContent(latestAfterDecision)) return;
    const failed = mergeTerminalDocumentSave(
      decision,
      restoreDocumentLifecycle(
        latestAfterDecision.documentLifecycle,
        latestAfterDecision.contentRevision ?? 0,
        latestAfterDecision.isDirty,
      ),
      claim.context,
      latestAfterDecision.content === latestAfterDecision.savedContent,
    );
    if (failed) {
      bufferStore.getState().actions.applyDocumentLifecycle(claim.context.bufferId, failed);
    } else {
      traceDocumentSaveCancellation(claim.context, "stale-failure-result");
    }
  } catch (lifecycleError) {
    traceDocumentSaveFailure(claim.context, lifecycleError);
    // Preserve text as dirty if the reducer itself is unavailable so the
    // document never remains owned by an unfinishable save operation.
    bufferStore.getState().actions.markBufferDirty(claim.context.bufferId, true);
  }
}

function showSaveFailure(bufferName: string, automatic = false) {
  const t = createTranslator(useSettingsStore.getState().settings.displayLanguage);
  toast.error(t(automatic ? "editor.autoSaveFailed" : "editor.saveFailed", { name: bufferName }));
}

/**
 * Drops queued autosave continuations that were waiting on a write which did not
 * save. Save paths outside the store closure cannot reach the scheduler, so they
 * route through the workspace store that owns the queued task.
 */
function cancelAutoSaveContinuations(workspaceId: string, operationId: string) {
  // A removed workspace already dropped its queued autosaves, and looking the
  // store up would recreate the runtime that the save just closed.
  if (!workspaceRuntimeRegistry.hasWorkspace(workspaceId)) return;
  useEditorAppStore
    .getStore(workspaceId)
    .getState()
    .actions.cancelAutoSaveContinuation(operationId);
}

function markBufferSavedIfUnchanged(
  workspaceId: string,
  bufferId: string,
  expectedContent: string,
  savedContent = expectedContent,
) {
  const bufferStore = useBufferStore.getStore(workspaceId);
  const latestBuffer = getBufferById(bufferStore.getState().buffers, bufferId);
  if (
    !latestBuffer ||
    !isEditorContent(latestBuffer) ||
    latestBuffer.content !== expectedContent
  ) {
    return false;
  }

  if (savedContent !== expectedContent) {
    bufferStore.getState().actions.updateBufferContent(bufferId, savedContent, false);
  }
  bufferStore.getState().actions.markBufferDirty(bufferId, false);
  return true;
}

async function saveEditorBufferById(
  workspaceId: string,
  bufferId: string,
  options: {
    targetEncoding?: FileEncoding;
    expectedEncoding?: FileEncoding;
    expectedIdentity?: string;
  } = {},
): Promise<EditorSaveResult> {
  const bufferStore = useBufferStore.getStore(workspaceId);
  const { buffers } = bufferStore.getState();
  const { markBufferDirty, updateBufferPath } = bufferStore.getState().actions;
  const { updateSettingsFromJSON } = useSettingsStore.getState().actions;
  const activeBuffer = getBufferById(buffers, bufferId);
  if (!activeBuffer || !isEditorContent(activeBuffer) || activeBuffer.readOnly) return "failed";
  if (!isBufferContentLoaded(activeBuffer)) {
    toast.error(bufferNotLoadedMessage(activeBuffer.name));
    return "failed";
  }

  let claimedSave: ClaimedDocumentSave | null = null;

  try {
    if (activeBuffer.path.startsWith("untitled:")) {
      const { save: saveDialog } = await import("@tauri-apps/plugin-dialog");
      const t = createTranslator(useSettingsStore.getState().settings.displayLanguage);
      const result = await saveDialog({
        title: t("ui.save"),
        defaultPath: activeBuffer.name,
        filters: [{ name: t("settings.common.allFiles"), extensions: ["*"] }],
      });
      if (!result) return "cancelled";

      const current = getBufferById(bufferStore.getState().buffers, bufferId);
      if (!current || !isEditorContent(current) || current.path !== activeBuffer.path) return "cancelled";
      const content = current.content;
      const baseline = await readDocumentFile(result);
      const outcome = await saveDocumentFile(result, content, baseline);
      if (outcome.status !== "saved") { showSaveFailure(current.name); return "cancelled"; }
      const latest = getBufferById(bufferStore.getState().buffers, bufferId);
      if (!latest || !isEditorContent(latest) || latest.path !== current.path) return "cancelled";
      updateBufferPath(activeBuffer.id, result);
      bufferStore.getState().actions.recordSuccessfulBufferSave(bufferId, content,
        latest.content === content
          ? { status: "clean", revision: latest.contentRevision ?? 0 }
          : { status: "dirty", revision: latest.contentRevision ?? 0, savedRevision: current.contentRevision ?? 0 });
      return "saved";
    }

    if (activeBuffer.isVirtual) {
      if (activeBuffer.path === "settings://user-settings.json") {
        const success = updateSettingsFromJSON(activeBuffer.content);
        markBufferDirty(activeBuffer.id, !success);
        if (!success) {
          showSaveFailure(activeBuffer.name);
          return "failed";
        }
        return "saved";
      }

      markBufferDirty(activeBuffer.id, false);
      return "saved";
    }

    if (activeBuffer.path.startsWith("remote://")) {
      markBufferDirty(activeBuffer.id, true);
      const pathParts = activeBuffer.path.replace("remote://", "").split("/");
      const connectionId = pathParts.shift();
      const remotePath = `/${pathParts.join("/")}`;

      if (!connectionId) {
        showSaveFailure(activeBuffer.name);
        return "failed";
      }

      await invoke("ssh_write_file", {
        connectionId,
        filePath: remotePath,
        content: activeBuffer.content,
      });
      markBufferSavedIfUnchanged(
        workspaceId,
        activeBuffer.id,
        activeBuffer.content,
      );
      return "saved";
    }

    let contentToSave = activeBuffer.content;
    const { settings } = useSettingsStore.getState();

    if (settings.formatOnSave && !options.targetEncoding) {
      const { formatContent } = await import("@/features/editor/formatter/formatter-service");
      const languageId = extensionRegistry.getLanguageId(activeBuffer.path);

      const formatResult = await formatContent({
        filePath: activeBuffer.path,
        content: activeBuffer.content,
        languageId: languageId || undefined,
      });

      if (formatResult.success && formatResult.formattedContent) {
        contentToSave = formatResult.formattedContent;
      }
    }

    const latestAfterFormat = getBufferById(bufferStore.getState().buffers, activeBuffer.id);
    if (!latestAfterFormat || !isEditorContent(latestAfterFormat) || latestAfterFormat.content !== activeBuffer.content || latestAfterFormat.path !== activeBuffer.path) return "cancelled";
    if (contentToSave !== activeBuffer.content) {
      bufferStore.getState().actions.updateBufferContent(activeBuffer.id, contentToSave, true);
    }
    const saveBuffer = getBufferById(bufferStore.getState().buffers, activeBuffer.id);
    if (!saveBuffer || !isEditorContent(saveBuffer)) return "cancelled";
    claimedSave = await claimDocumentSave(workspaceId, saveBuffer);
    if (!claimedSave) return "cancelled";

    await recordLocalHistoryBeforeWrite(activeBuffer.path, "save");
    const expectedContent = saveBuffer.acknowledgedDiskContent === undefined ? saveBuffer.savedContent : saveBuffer.acknowledgedDiskContent;
    const persisted = await persistClaimedDocument(
      workspaceId,
      claimedSave,
      contentToSave,
      expectedContent,
      options.targetEncoding ?? saveBuffer.saveEncoding ?? saveBuffer.readEncoding ?? saveBuffer.encoding,
      options.expectedEncoding ?? saveBuffer.saveEncoding ?? saveBuffer.readEncoding ?? saveBuffer.encoding,
      options.expectedIdentity ?? saveBuffer.diskIdentity,
    );
    if (!persisted.saved) {
      cancelAutoSaveContinuations(workspaceId, claimedSave.context.operationId);
      return "cancelled";
    }
    await finishDocumentSave(workspaceId, claimedSave, contentToSave);

    try {
      const { LspClient } = await import("@/features/editor/lsp/lsp-client");
      await LspClient.getInstance().notifyDocumentSave(activeBuffer.path, contentToSave);

      if (settings.lintOnSave) {
        const { lintContent } = await import("@/features/editor/linter/linter-service");
        const { convertLintDiagnostic, useDiagnosticsStore } =
          await import("@/features/diagnostics/stores/diagnostics.store");
        const languageId = extensionRegistry.getLanguageId(activeBuffer.path);

        const lintResult = await lintContent({
          filePath: activeBuffer.path,
          content: contentToSave,
          languageId: languageId || undefined,
        });

        if (lintResult.success && lintResult.diagnostics) {
          useDiagnosticsStore.getState().actions.setDiagnostics(
            activeBuffer.path,
            lintResult.diagnostics.map((diagnostic) =>
              convertLintDiagnostic(activeBuffer.path, diagnostic),
            ),
            "linter",
          );
        }
      }

      const rootFolderPath = useFileSystemStore.getStore(workspaceId).getState().rootFolderPath;
      if (rootFolderPath) {
        emitGitChanged({
          repoPath: rootFolderPath,
          filePath: activeBuffer.path,
          scopes: ["working-tree"],
          source: "save",
        });
      }
    } catch (error) {
      console.warn("Post-save editor services failed:", error);
    }
    return "saved";
  } catch (error) {
    console.error("Error saving file:", error);
    if (claimedSave) {
      cancelAutoSaveContinuations(workspaceId, claimedSave.context.operationId);
      await rejectDocumentSave(workspaceId, claimedSave, error);
    } else {
      markBufferDirty(activeBuffer.id, true);
    }
    showSaveFailure(activeBuffer.name);
    return "failed";
  }
}

function getDirtyEditorBuffers(buffers: PaneContent[]): EditorContent[] {
  return buffers.filter(
    (buffer): buffer is EditorContent =>
      isEditorContent(buffer) && buffer.isDirty && !buffer.readOnly,
  );
}

/** One queued autosave debounce, optionally continuing an in-flight write. */
interface AutoSaveTask {
  timeoutId: ReturnType<typeof setTimeout>;
  context: DocumentSaveContext;
  /**
   * Set when this debounce continues an in-flight write instead of a fresh edit:
   * the id of the write it waits on. When that write fails, conflicts, or is
   * cancelled, the continuation is dropped so the newer text stays unsaved.
   */
  continuesOperationId?: string;
}

interface AppState {
  autoSaveTasks: Record<string, AutoSaveTask>;
  quickEditState: {
    isOpen: boolean;
    selectedText: string;
    cursorPosition: { x: number; y: number };
    selectionRange: { start: number; end: number };
  };
  actions: AppActions;
}

interface AppActions {
  handleContentChange: (
    bufferId: string,
    content: string,
    previousContent?: string,
    previousCursorPosition?: Position,
    previousSelection?: Range,
    options?: EditorContentChangeOptions,
  ) => Promise<void>;
  handleSave: (bufferId?: string) => Promise<EditorSaveResult>;
  saveWithEncoding: (encoding: FileEncoding, bufferId?: string) => Promise<EditorSaveResult>;
  handleSaveAll: () => Promise<number>;
  openQuickEdit: (params: {
    text: string;
    cursorPosition: { x: number; y: number };
    selectionRange: { start: number; end: number };
  }) => void;
  cleanup: () => void;
  /**
   * Drops a queued autosave continuation that was waiting on `operationId`. A
   * continuation must not outlive a write that failed or conflicted.
   */
  cancelAutoSaveContinuation: (operationId: string) => void;
}

/** Timer seam so autosave debounce can be driven without wall-clock waits in tests. */
export interface EditorAppScheduler {
  setTimer: (
    callback: () => void | Promise<void>,
    milliseconds: number,
  ) => ReturnType<typeof setTimeout>;
  clearTimer: (timer: ReturnType<typeof setTimeout>) => void;
}

const defaultEditorAppScheduler: EditorAppScheduler = {
  setTimer: (callback, milliseconds) => setTimeout(() => void callback(), milliseconds),
  clearTimer: (timer) => clearTimeout(timer),
};

/** Debounce window that batches a burst of edits into one write. */
const AUTO_SAVE_DELAY_MILLISECONDS = 150;

export const createEditorAppStore = (
  workspaceId: string,
  scheduler: EditorAppScheduler = defaultEditorAppScheduler,
) =>
  createStore<AppState>()(
    immer((set, get) => ({
      autoSaveTasks: {},
      quickEditState: {
        isOpen: false,
        selectedText: "",
        cursorPosition: { x: 0, y: 0 },
        selectionRange: { start: 0, end: 0 },
      },
      actions: {
        handleContentChange: async (
          bufferId: string,
          content: string,
          previousContent?: string,
          previousCursorPosition?: Position,
          previousSelection?: Range,
          options?: EditorContentChangeOptions,
        ) => {
          const bufferStore = useBufferStore.getStore(workspaceId);
          const { buffers } = bufferStore.getState();
          const { updateBufferContent, markBufferDirty } = bufferStore.getState().actions;
          const { settings } = useSettingsStore.getState();
          const contentAlreadyApplied = options?.contentAlreadyApplied === true;

          const activeBuffer = getBufferById(buffers, bufferId);
          if (!activeBuffer || !isEditorContent(activeBuffer)) return;

          if (
            !contentAlreadyApplied &&
            (options?.contentChanges?.length || options?.contentChange)
          ) {
            queueEditorViewContentChange(
              bufferId,
              activeBuffer.content,
              content,
              options.contentChanges ?? (options.contentChange ? [options.contentChange] : []),
            );
          }

          trackBufferHistoryChange({
            bufferId,
            currentContent: activeBuffer.content,
            nextContent: content,
            previousContent,
            previousCursorPosition,
            previousSelection,
            skipUndoGrouping: options?.skipUndoGrouping,
            contentChange: options?.contentChange,
          });

          const isRemoteFile = activeBuffer.path.startsWith("remote://");

          if (isRemoteFile) {
            if (!contentAlreadyApplied) {
              updateBufferContent(activeBuffer.id, content, true);
            }
          } else {
            if (!contentAlreadyApplied) {
              updateBufferContent(activeBuffer.id, content, true);
            }

            // Arms the debounced autosave; a later edit replaces this pending timer.
            const armAutoSave = (
              target: { path: string; name: string },
              text: string,
              continuesOperationId?: string,
            ) => {
              const previousAutoSave = get().autoSaveTasks[bufferId];
              if (previousAutoSave) {
                scheduler.clearTimer(previousAutoSave.timeoutId);
                traceDocumentSaveCancellation(previousAutoSave.context, "superseded-by-edit");
              }
              const autoSaveContext: DocumentSaveContext = {
                bufferId,
                path: target.path,
                operationId: crypto.randomUUID(),
              };
              const timeoutId = scheduler.setTimer(() => {
                void runAutoSave(autoSaveContext, text, target);
              }, AUTO_SAVE_DELAY_MILLISECONDS);

              set((state) => {
                state.autoSaveTasks[bufferId] = {
                  timeoutId,
                  context: autoSaveContext,
                  continuesOperationId,
                };
              });
            };

            const runAutoSave = async (
              autoSaveContext: DocumentSaveContext,
              text: string,
              target: { path: string; name: string },
            ) => {
              let claim: ClaimedDocumentSave | null = null;
              try {
                // Autosave can be switched off while this debounce is queued.
                if (!useSettingsStore.getState().settings.autoSave) {
                  traceDocumentSaveCancellation(autoSaveContext, "auto-save-disabled");
                  return;
                }
                const latestBeforeSave = getBufferById(
                  bufferStore.getState().buffers,
                  bufferId,
                );
                if (
                  !latestBeforeSave ||
                  !isEditorContent(latestBeforeSave) ||
                  latestBeforeSave.content !== text
                ) {
                  traceDocumentSaveCancellation(autoSaveContext, "stale-content");
                  return;
                }
                claim = await claimDocumentSave(
                  workspaceId,
                  latestBeforeSave,
                  autoSaveContext.operationId,
                );
                if (!claim) {
                  // Another write, manual or an earlier autosave, still owns this
                  // document. Continue with this text once that write succeeds;
                  // otherwise the newer revision stays dirty forever. Each wait
                  // re-reads live state, so it ends when the text is superseded,
                  // the document closes, autosave turns off, or the awaited write
                  // fails or conflicts and drops every continuation of its id.
                  const latest = getBufferById(bufferStore.getState().buffers, bufferId);
                  const ownerOperationId =
                    latest &&
                    isEditorContent(latest) &&
                    latest.documentLifecycle?.status === "saving"
                      ? latest.documentLifecycle.operationId
                      : undefined;
                  if (
                    latest &&
                    isEditorContent(latest) &&
                    latest.isDirty &&
                    latest.content === text &&
                    latest.path === target.path &&
                    ownerOperationId &&
                    useSettingsStore.getState().settings.autoSave
                  ) {
                    armAutoSave({ path: latest.path, name: latest.name }, text, ownerOperationId);
                  }
                  return;
                }
                await recordLocalHistoryBeforeWrite(target.path, "auto-save");
                const expectedContent = latestBeforeSave.acknowledgedDiskContent === undefined
                  ? latestBeforeSave.savedContent
                  : latestBeforeSave.acknowledgedDiskContent;
                const saveEncoding = latestBeforeSave.saveEncoding ?? latestBeforeSave.readEncoding ?? latestBeforeSave.encoding;
                const persisted = await persistClaimedDocument(
                  workspaceId,
                  claim,
                  text,
                  expectedContent,
                  saveEncoding,
                  saveEncoding,
                  latestBeforeSave.diskIdentity,
                );
                if (!persisted.saved) {
                  // A conflict or lost ownership ends the wait; the newer text
                  // must stay unsaved instead of being written by the waiter.
                  get().actions.cancelAutoSaveContinuation(autoSaveContext.operationId);
                  return;
                }
                await finishDocumentSave(workspaceId, claim, text);

                const rootFolderPath = useFileSystemStore
                  .getStore(workspaceId)
                  .getState().rootFolderPath;
                if (rootFolderPath) {
                  emitGitChanged({
                    repoPath: rootFolderPath,
                    filePath: target.path,
                    scopes: ["working-tree"],
                    source: "auto-save",
                  });
                }
              } catch (error) {
                console.error("Error saving file:", error);
                get().actions.cancelAutoSaveContinuation(autoSaveContext.operationId);
                if (claim) await rejectDocumentSave(workspaceId, claim, error);
                else markBufferDirty(bufferId, true);
                showSaveFailure(target.name, true);
              } finally {
                set((state) => {
                  if (
                    state.autoSaveTasks[bufferId]?.context.operationId ===
                    autoSaveContext.operationId
                  ) {
                    delete state.autoSaveTasks[bufferId];
                  }
                });
              }
            };

            if (
              !activeBuffer.isVirtual &&
              !activeBuffer.path.startsWith("untitled:") &&
              settings.autoSave
            ) {
              armAutoSave(activeBuffer, content);
            }
          }
        },

        handleSave: async (bufferId?: string) => {
          const bufferStore = useBufferStore.getStore(workspaceId);
          const { activeBufferId, buffers } = bufferStore.getState();
          const targetBufferId = bufferId ?? activeBufferId;
          const activeBuffer = getBufferById(buffers, targetBufferId);
          if (!activeBuffer || !isEditorContent(activeBuffer) || activeBuffer.readOnly) {
            return "failed";
          }

          const result = await saveEditorBufferById(workspaceId, activeBuffer.id);
          if (result !== "saved") return result;

          const savedBuffer = getBufferById(bufferStore.getState().buffers, activeBuffer.id);
          return savedBuffer && isEditorContent(savedBuffer) && savedBuffer.isDirty
            ? "failed"
            : "saved";
        },

        saveWithEncoding: async (encoding: FileEncoding, bufferId?: string) => {
          const bufferStore = useBufferStore.getStore(workspaceId);
          const targetId = bufferId ?? bufferStore.getState().activeBufferId;
          const current = getBufferById(bufferStore.getState().buffers, targetId);
          if (!current || !isEditorContent(current)) return "failed";
          if (!isLocalDocumentPath(current.path) || current.isVirtual || current.readOnly || !isBufferContentLoaded(current)) return "failed";
          if (current.documentLifecycle?.status === "saving" || current.documentLifecycle?.status === "conflict") return "cancelled";
          if (!current.isDirty && (current.saveEncoding ?? current.readEncoding ?? current.encoding) === encoding) return "saved";
          const pendingAutoSave = get().autoSaveTasks[current.id];
          if (pendingAutoSave) {
            scheduler.clearTimer(pendingAutoSave.timeoutId);
            set((state) => { delete state.autoSaveTasks[current.id]; });
          }
          const wasDirty = current.isDirty;
          const startRevision = current.contentRevision ?? 0;
          if (!wasDirty) bufferStore.getState().actions.markBufferDirty(current.id, true);
          const result = await saveEditorBufferById(workspaceId, current.id, {
            targetEncoding: encoding,
            expectedEncoding: current.saveEncoding ?? current.readEncoding ?? current.encoding ?? "UTF-8",
            expectedIdentity: current.diskIdentity,
          });
          if (result !== "saved" && !wasDirty) {
            const latest = getBufferById(bufferStore.getState().buffers, current.id);
            if (latest?.type === "editor" && latest.path === current.path &&
                (latest.contentRevision ?? 0) === startRevision && latest.documentLifecycle?.status === "dirty") {
              bufferStore.getState().actions.markBufferDirty(current.id, false);
            }
          }
          return result;
        },

        handleSaveAll: async () => {
          const bufferStore = useBufferStore.getStore(workspaceId);
          const dirtyBufferIds = getDirtyEditorBuffers(bufferStore.getState().buffers).map(
            (buffer) => buffer.id,
          );
          const saveResults = await Promise.all(
            dirtyBufferIds.map(async (bufferId) => {
              const result = await saveEditorBufferById(workspaceId, bufferId);
              const nextBuffer = getBufferById(bufferStore.getState().buffers, bufferId);
              return (
                result === "saved" &&
                (!nextBuffer || !isEditorContent(nextBuffer) || !nextBuffer.isDirty)
              );
            }),
          );

          return saveResults.filter(Boolean).length;
        },

        openQuickEdit: (params) => {
          set((state) => {
            state.quickEditState = {
              isOpen: true,
              selectedText: params.text,
              cursorPosition: params.cursorPosition,
              selectionRange: params.selectionRange,
            };
          });
        },

        cleanup: () => {
          const { autoSaveTasks } = get();
          for (const task of Object.values(autoSaveTasks)) {
            scheduler.clearTimer(task.timeoutId);
            traceDocumentSaveCancellation(task.context, "workspace-cleanup");
          }
          set((state) => {
            state.autoSaveTasks = {};
          });
        },

        cancelAutoSaveContinuation: (operationId: string) => {
          for (const [bufferId, task] of Object.entries(get().autoSaveTasks)) {
            if (task.continuesOperationId !== operationId) continue;
            scheduler.clearTimer(task.timeoutId);
            traceDocumentSaveCancellation(task.context, "predecessor-write-not-saved");
            set((state) => {
              delete state.autoSaveTasks[bufferId];
            });
          }
        },
      },
    })),
  );

export const useEditorAppStore = createSelectors(
  createWorkspaceScopedStore("editor-app", createEditorAppStore),
);
