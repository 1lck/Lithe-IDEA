import { isEditorContent } from "@/features/panes/types/pane-content.types";
import { useBufferStore } from "../stores/buffer.store";
import { useEditorAppStore } from "../stores/editor-app.store";

function hasActiveWritableSave(workspaceId: string): boolean {
  return useBufferStore
    .getStore(workspaceId)
    .getState()
    .buffers.some(
      (buffer) =>
        isEditorContent(buffer) &&
        !buffer.readOnly &&
        buffer.documentLifecycle?.status === "saving",
    );
}

async function waitForActiveWorkspaceSaves(workspaceId: string): Promise<void> {
  if (!hasActiveWritableSave(workspaceId)) return;

  const bufferStore = useBufferStore.getStore(workspaceId);
  await new Promise<void>((resolve) => {
    let unsubscribe = () => {};
    const resolveWhenIdle = () => {
      if (hasActiveWritableSave(workspaceId)) return;
      unsubscribe();
      resolve();
    };
    unsubscribe = bufferStore.subscribe(resolveWhenIdle);
    resolveWhenIdle();
  });
}

function unsavedWritableBufferNames(workspaceId: string): string[] {
  const names = useBufferStore
    .getStore(workspaceId)
    .getState()
    .buffers.filter(
      (buffer) => isEditorContent(buffer) && buffer.isDirty && !buffer.readOnly,
    )
    .map((buffer) => buffer.name);
  return [...new Set(names)].sort();
}

export async function saveWorkspaceBeforeLaunch(workspaceId: string): Promise<void> {
  while (true) {
    await waitForActiveWorkspaceSaves(workspaceId);
    await useEditorAppStore.getStore(workspaceId).getState().actions.handleSaveAll();
    const unsavedNames = unsavedWritableBufferNames(workspaceId);
    if (unsavedNames.length === 0) return;
    if (hasActiveWritableSave(workspaceId)) continue;

    throw new Error(
      `Unable to start because modified files could not be saved: ${unsavedNames.join(", ")}.`,
    );
  }
}
