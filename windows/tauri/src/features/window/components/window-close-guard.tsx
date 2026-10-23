import { getCurrentWebviewWindow } from "@tauri-apps/api/webviewWindow";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { useCallback, useEffect, useRef, useState } from "react";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { useEditorAppStore } from "@/features/editor/stores/editor-app.store";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { isEditorContent } from "@/features/panes/types/pane-content.types";
import RunningServicesDialog from "@/features/window/components/running-services-dialog";
import UnsavedChangesDialog from "@/features/window/components/unsaved-changes-dialog";
import {
  answerRunServicesPrompt,
  stopRunServicesBeforeLeaving,
  useRunServicesPromptStore,
} from "@/features/window/services/run-services-exit";
import {
  APPLICATION_QUIT_EVENT,
  REQUEST_WINDOW_CLOSE_EVENT,
} from "@/features/window/utils/request-window-close";
import { useActiveWorkspaceId } from "@/features/workspace/stores/create-workspace-scoped-store";

interface PendingWindowClose {
  bufferId: string;
  fileName: string;
}

/** Closing one window, or this window's part of quitting Lithe. */
type ClosePurpose = "closeWindow" | "quit";

function getBlockingDirtyBuffer(workspaceId: string, discardedBufferIds: Set<string>) {
  return useBufferStore
    .getStore(workspaceId)
    .getState()
    .buffers.find(
      (buffer) => isEditorContent(buffer) && buffer.isDirty && !discardedBufferIds.has(buffer.id),
    );
}

/**
 * Every way of closing the window or quitting Lithe passes through here: the
 * title bar, Alt+F4, the menu and the taskbar. Unsaved files are asked about
 * first, because saving may still be cancelled; Run services are asked about
 * last and stopped before the window really closes.
 */
export function WindowCloseGuard() {
  const workspaceId = useActiveWorkspaceId();
  const [pendingClose, setPendingClose] = useState<PendingWindowClose | null>(null);
  const runServicesPrompt = useRunServicesPromptStore((state) => state.prompt);
  const closeInProgressRef = useRef(false);
  const checkingRef = useRef(false);
  const purposeRef = useRef<ClosePurpose>("closeWindow");
  const discardedBufferIdsRef = useRef(new Set<string>());
  const persistActiveProjectSession = useFileSystemStore(
    (state) => state.persistActiveProjectSession,
  );
  const { handleSave } = useEditorAppStore.use.actions();

  const persistSessionSnapshot = useCallback(() => {
    useFileSystemStore.getStore(workspaceId).getState().persistActiveProjectSession();
  }, [workspaceId]);

  const continueCloseOrPrompt = useCallback(async () => {
    if (checkingRef.current) return;
    const dirtyBuffer = getBlockingDirtyBuffer(workspaceId, discardedBufferIdsRef.current);

    if (dirtyBuffer) {
      setPendingClose({
        bufferId: dirtyBuffer.id,
        fileName: dirtyBuffer.name,
      });
      return;
    }

    checkingRef.current = true;
    try {
      const stopped = await stopRunServicesBeforeLeaving("window", purposeRef.current);
      if (!stopped) {
        discardedBufferIdsRef.current.clear();
        return;
      }
    } finally {
      checkingRef.current = false;
    }

    persistSessionSnapshot();
    closeInProgressRef.current = true;
    await getCurrentWindow().close();
  }, [persistSessionSnapshot, workspaceId]);

  const requestClose = useCallback(
    (purpose: ClosePurpose) => {
      if (checkingRef.current) return;
      purposeRef.current = purpose;
      void continueCloseOrPrompt();
    },
    [continueCloseOrPrompt],
  );

  useEffect(() => {
    let disposed = false;
    let unlistenClose: (() => void) | undefined;
    let unlistenQuit: (() => void) | undefined;
    let unlistenMenuCloseWindow: (() => void) | undefined;
    const requestWindowClose = () => requestClose("closeWindow");

    const setupCloseGuard = async () => {
      const currentWindow = getCurrentWindow();
      const currentWebviewWindow = getCurrentWebviewWindow();

      unlistenClose = await currentWindow.onCloseRequested((event) => {
        if (closeInProgressRef.current) {
          persistSessionSnapshot();
          return;
        }
        // The checks need the native host, so the close is held and repeated
        // once they pass.
        event.preventDefault();
        requestClose("closeWindow");
      });

      unlistenQuit = await currentWebviewWindow.listen(APPLICATION_QUIT_EVENT, () => {
        requestClose("quit");
      });

      unlistenMenuCloseWindow = await currentWebviewWindow.listen("menu_close_window", () => {
        requestClose("closeWindow");
      });

      if (disposed) {
        unlistenClose();
        unlistenQuit();
        unlistenMenuCloseWindow();
      }
    };

    void setupCloseGuard();
    window.addEventListener("beforeunload", persistActiveProjectSession);
    window.addEventListener(REQUEST_WINDOW_CLOSE_EVENT, requestWindowClose);

    return () => {
      disposed = true;
      unlistenClose?.();
      unlistenQuit?.();
      unlistenMenuCloseWindow?.();
      window.removeEventListener("beforeunload", persistActiveProjectSession);
      window.removeEventListener(REQUEST_WINDOW_CLOSE_EVENT, requestWindowClose);
    };
  }, [persistActiveProjectSession, persistSessionSnapshot, requestClose]);

  const handleSaveAndContinue = useCallback(async () => {
    if (!pendingClose) return;

    const result = await handleSave(pendingClose.bufferId);
    if (result !== "saved") return;

    setPendingClose(null);
    await continueCloseOrPrompt();
  }, [continueCloseOrPrompt, handleSave, pendingClose]);

  const handleDiscardAndContinue = useCallback(async () => {
    if (!pendingClose) return;

    discardedBufferIdsRef.current.add(pendingClose.bufferId);
    setPendingClose(null);
    await continueCloseOrPrompt();
  }, [continueCloseOrPrompt, pendingClose]);

  const handleCancel = useCallback(() => {
    discardedBufferIdsRef.current.clear();
    closeInProgressRef.current = false;
    setPendingClose(null);
  }, []);

  if (runServicesPrompt) {
    return (
      <RunningServicesDialog
        prompt={runServicesPrompt}
        onStop={() => answerRunServicesPrompt("stop")}
        onCancel={() => answerRunServicesPrompt("cancel")}
      />
    );
  }

  if (!pendingClose) {
    return null;
  }

  return (
    <UnsavedChangesDialog
      fileName={pendingClose.fileName}
      onSave={() => void handleSaveAndContinue()}
      onDiscard={() => void handleDiscardAndContinue()}
      onCancel={handleCancel}
    />
  );
}
