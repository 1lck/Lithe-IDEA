import { invoke } from "@/platform/tauri-core";
import { toast } from "sonner";
import { immer } from "zustand/middleware/immer";
import { createStore } from "zustand/vanilla";
import { extensionRegistry } from "@/extensions/registry/extension-registry";
import { parseCollaborationNoteBufferPath } from "@/features/collaboration/lib/collaboration-sidebar-model";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { useFileWatcherStore } from "@/features/file-system/stores/file-watcher.store";
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

function showSaveFailure(bufferName: string, automatic = false) {
  const t = createTranslator(useSettingsStore.getState().settings.displayLanguage);
  toast.error(t(automatic ? "editor.autoSaveFailed" : "editor.saveFailed", { name: bufferName }));
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
): Promise<EditorSaveResult> {
  const bufferStore = useBufferStore.getStore(workspaceId);
  const { buffers } = bufferStore.getState();
  const { markBufferDirty, updateBufferPath } = bufferStore.getState().actions;
  const { updateSettingsFromJSON } = useSettingsStore.getState().actions;
  const { markPendingSave } = useFileWatcherStore.getStore(workspaceId).getState().actions;
  const activeBuffer = getBufferById(buffers, bufferId);
  if (!activeBuffer || !isEditorContent(activeBuffer) || activeBuffer.readOnly) return "failed";

  const collaborationNoteTarget = parseCollaborationNoteBufferPath(activeBuffer.path);

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

      await writeFile(result, activeBuffer.content);
      updateBufferPath(activeBuffer.id, result);
      markBufferDirty(activeBuffer.id, false);
      return "saved";
    }

    if (collaborationNoteTarget) {
      const { updateCollaborationChannelNote } =
        await import("@/features/window/services/auth-api");
      const { useAuthStore } = await import("@/features/window/stores/auth.store");
      const { updateCollaborationNoteFile } =
        await import("@/features/collaboration/lib/collaboration-sidebar-model");
      const { subscription, actions } = useAuthStore.getState();
      const collaboration = subscription?.collaboration;
      const channelNote = collaboration?.channelNotes.find(
        (note) => note.channelId === collaborationNoteTarget.channelId,
      );

      if (!channelNote) {
        markBufferDirty(activeBuffer.id, true);
        showSaveFailure(activeBuffer.name);
        return "failed";
      }

      const nextCollaboration = await updateCollaborationChannelNote({
        channelId: collaborationNoteTarget.channelId,
        contentMarkdown: updateCollaborationNoteFile({
          contentMarkdown: channelNote.contentMarkdown,
          path: collaborationNoteTarget.notePath,
          fileContent: activeBuffer.content,
        }),
      });
      actions.setCollaborationSnapshot(nextCollaboration);
      markBufferSavedIfUnchanged(
        workspaceId,
        activeBuffer.id,
        activeBuffer.content,
      );
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

    markPendingSave(activeBuffer.path);

    let contentToSave = activeBuffer.content;
    const { settings } = useSettingsStore.getState();

    if (settings.formatOnSave) {
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

    await recordLocalHistoryBeforeWrite(activeBuffer.path, "save");
    await writeFile(activeBuffer.path, contentToSave);
    markBufferSavedIfUnchanged(
      workspaceId,
      activeBuffer.id,
      activeBuffer.content,
      contentToSave,
    );

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
    markBufferDirty(activeBuffer.id, true);
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

interface AppState {
  autoSaveTimeoutId: NodeJS.Timeout | null;
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
  handleSaveAll: () => Promise<number>;
  openQuickEdit: (params: {
    text: string;
    cursorPosition: { x: number; y: number };
    selectionRange: { start: number; end: number };
  }) => void;
  cleanup: () => void;
}

const createEditorAppStore = (workspaceId: string) =>
  createStore<AppState>()(
    immer((set, get) => ({
      autoSaveTimeoutId: null,
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
          const { markPendingSave } = useFileWatcherStore.getStore(workspaceId).getState().actions;
          const contentAlreadyApplied = options?.contentAlreadyApplied === true;

          const activeBuffer = getBufferById(buffers, bufferId);
          if (!activeBuffer || !isEditorContent(activeBuffer)) return;
          const collaborationNoteTarget = parseCollaborationNoteBufferPath(activeBuffer.path);

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
              updateBufferContent(activeBuffer.id, content, true, undefined, { local: true });
            }
          } else if (collaborationNoteTarget) {
            if (!contentAlreadyApplied) {
              updateBufferContent(activeBuffer.id, content, true, undefined, { local: true });
            }
            markBufferDirty(activeBuffer.id, content !== activeBuffer.savedContent);
          } else {
            if (!contentAlreadyApplied) {
              updateBufferContent(activeBuffer.id, content, true, undefined, { local: true });
            }

            if (
              !activeBuffer.isVirtual &&
              !activeBuffer.path.startsWith("untitled:") &&
              settings.autoSave
            ) {
              const { autoSaveTimeoutId } = get();
              if (autoSaveTimeoutId) {
                clearTimeout(autoSaveTimeoutId);
              }

              const newTimeoutId = setTimeout(async () => {
                try {
                  markPendingSave(activeBuffer.path);
                  await recordLocalHistoryBeforeWrite(activeBuffer.path, "auto-save");
                  await writeFile(activeBuffer.path, content);
                  markBufferSavedIfUnchanged(workspaceId, bufferId, content);

                  const rootFolderPath = useFileSystemStore
                    .getStore(workspaceId)
                    .getState().rootFolderPath;
                  if (rootFolderPath) {
                    emitGitChanged({
                      repoPath: rootFolderPath,
                      filePath: activeBuffer.path,
                      scopes: ["working-tree"],
                      source: "auto-save",
                    });
                  }
                } catch (error) {
                  console.error("Error saving file:", error);
                  const latestBuffer = getBufferById(bufferStore.getState().buffers, bufferId);
                  if (
                    latestBuffer &&
                    isEditorContent(latestBuffer) &&
                    latestBuffer.content === content
                  ) {
                    markBufferDirty(bufferId, true);
                    showSaveFailure(activeBuffer.name, true);
                  }
                }
              }, 150);

              set((state) => {
                state.autoSaveTimeoutId = newTimeoutId;
              });
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
          const { autoSaveTimeoutId } = get();
          if (autoSaveTimeoutId) {
            clearTimeout(autoSaveTimeoutId);
          }
        },
      },
    })),
  );

export const useEditorAppStore = createSelectors(
  createWorkspaceScopedStore("editor-app", createEditorAppStore),
);
