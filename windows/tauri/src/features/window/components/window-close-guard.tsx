import { getCurrentWebviewWindow } from "@tauri-apps/api/webviewWindow";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { useCallback, useEffect, useRef, useState } from "react";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { useEditorAppStore } from "@/features/editor/stores/editor-app.store";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { isEditorContent } from "@/features/panes/types/pane-content.types";
import { activeRunServices, type ActiveRunService } from "@/features/run/stores/run.store";
import RunningServicesDialog from "@/features/window/components/running-services-dialog";
import UnsavedChangesDialog from "@/features/window/components/unsaved-changes-dialog";
import { REQUEST_WINDOW_CLOSE_EVENT } from "@/features/window/utils/request-window-close";
import { useActiveWorkspaceId } from "@/features/workspace/stores/create-workspace-scoped-store";

interface PendingWindowClose {
  bufferId: string;
  fileName: string;
}

function getBlockingDirtyBuffer(workspaceId: string, discardedBufferIds: Set<string>) {
  return useBufferStore
    .getStore(workspaceId)
    .getState()
    .buffers.find(
      (buffer) => isEditorContent(buffer) && buffer.isDirty && !discardedBufferIds.has(buffer.id),
    );
}

export function WindowCloseGuard() {
  const workspaceId = useActiveWorkspaceId();
  const [pendingClose, setPendingClose] = useState<PendingWindowClose | null>(null);
  const [runningServices, setRunningServices] = useState<ActiveRunService[] | null>(null);
  const [stoppingServices, setStoppingServices] = useState(false);
  const closeInProgressRef = useRef(false);
  const discardedBufferIdsRef = useRef(new Set<string>());
  const persistActiveProjectSession = useFileSystemStore(
    (state) => state.persistActiveProjectSession,
  );
  const { handleSave } = useEditorAppStore.use.actions();

  const persistSessionSnapshot = useCallback(() => {
    useFileSystemStore.getStore(workspaceId).getState().persistActiveProjectSession();
  }, [workspaceId]);

  const continueCloseOrPrompt = useCallback(async () => {
    const dirtyBuffer = getBlockingDirtyBuffer(workspaceId, discardedBufferIdsRef.current);

    if (dirtyBuffer) {
      setPendingClose({
        bufferId: dirtyBuffer.id,
        fileName: dirtyBuffer.name,
      });
      return;
    }

    // Asked after unsaved files: saving may still be cancelled, and services
    // must keep running until the window is really going to close.
    const services = activeRunServices();
    if (services.length > 0) {
      setRunningServices(services);
      return;
    }

    persistSessionSnapshot();
    closeInProgressRef.current = true;
    await getCurrentWindow().close();
  }, [persistSessionSnapshot, workspaceId]);

  useEffect(() => {
    let disposed = false;
    let unlistenClose: (() => void) | undefined;
    let unlistenQuit: (() => void) | undefined;
    let unlistenMenuCloseWindow: (() => void) | undefined;

    const setupCloseGuard = async () => {
      const currentWindow = getCurrentWindow();
      const currentWebviewWindow = getCurrentWebviewWindow();

      unlistenClose = await currentWindow.onCloseRequested((event) => {
        if (closeInProgressRef.current) {
          persistSessionSnapshot();
          return;
        }

        const dirtyBuffer = getBlockingDirtyBuffer(workspaceId, discardedBufferIdsRef.current);
        if (dirtyBuffer) {
          event.preventDefault();
          setPendingClose({
            bufferId: dirtyBuffer.id,
            fileName: dirtyBuffer.name,
          });
          return;
        }

        const services = activeRunServices();
        if (services.length > 0) {
          event.preventDefault();
          setRunningServices(services);
          return;
        }

        persistSessionSnapshot();
      });

      unlistenQuit = await currentWebviewWindow.listen("menu_quit_app", () => {
        void continueCloseOrPrompt();
      });

      unlistenMenuCloseWindow = await currentWebviewWindow.listen("menu_close_window", () => {
        void continueCloseOrPrompt();
      });

      if (disposed) {
        unlistenClose();
        unlistenQuit();
        unlistenMenuCloseWindow();
      }
    };

    void setupCloseGuard();
    window.addEventListener("beforeunload", persistActiveProjectSession);
    window.addEventListener(REQUEST_WINDOW_CLOSE_EVENT, continueCloseOrPrompt);

    return () => {
      disposed = true;
      unlistenClose?.();
      unlistenQuit?.();
      unlistenMenuCloseWindow?.();
      window.removeEventListener("beforeunload", persistActiveProjectSession);
      window.removeEventListener(REQUEST_WINDOW_CLOSE_EVENT, continueCloseOrPrompt);
    };
  }, [continueCloseOrPrompt, persistActiveProjectSession, persistSessionSnapshot, workspaceId]);

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
    setRunningServices(null);
  }, []);

  const handleStopServicesAndClose = useCallback(async () => {
    if (!runningServices || stoppingServices) return;

    setStoppingServices(true);
    try {
      // Each stop waits for the native process tree to end. The host still
      // reaps anything left when the window is destroyed.
      await Promise.all(runningServices.map((service) => service.stop()));
    } finally {
      setStoppingServices(false);
      setRunningServices(null);
    }
    // Asks again if a service was started while the others were stopping.
    await continueCloseOrPrompt();
  }, [continueCloseOrPrompt, runningServices, stoppingServices]);

  if (runningServices) {
    return (
      <RunningServicesDialog
        serviceTitles={runningServices.map((service) => service.title)}
        stopping={stoppingServices}
        onStopAndClose={() => void handleStopServicesAndClose()}
        onCancel={handleCancel}
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
