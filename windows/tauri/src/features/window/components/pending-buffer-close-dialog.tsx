import { useCallback } from "react";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { getBufferById } from "@/features/editor/utils/buffer-index";
import { useEditorAppStore } from "@/features/editor/stores/editor-app.store";
import UnsavedChangesDialog from "@/features/window/components/unsaved-changes-dialog";

export function PendingBufferCloseDialog() {
  const pendingClose = useBufferStore.use.pendingClose();
  const fileName = useBufferStore((state) => {
    if (!state.pendingClose) return "";
    return getBufferById(state.buffers, state.pendingClose.bufferId)?.name ?? "";
  });
  const { confirmCloseWithoutSaving, cancelPendingClose } = useBufferStore.use.actions();
  const { handleSave } = useEditorAppStore.use.actions();

  const handleSaveAndClose = useCallback(async () => {
    if (!pendingClose) return;
    await handleSave();
    confirmCloseWithoutSaving();
  }, [confirmCloseWithoutSaving, handleSave, pendingClose]);

  if (!pendingClose) return null;

  return (
    <UnsavedChangesDialog
      fileName={fileName}
      onSave={() => void handleSaveAndClose()}
      onDiscard={confirmCloseWithoutSaving}
      onCancel={cancelPendingClose}
    />
  );
}
