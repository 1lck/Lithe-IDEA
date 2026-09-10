import { editorAPI } from "@/features/editor/extensions/api";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import type { JumpListEntry } from "@/features/editor/stores/jump-list.store";
import { getBufferById, getBufferByPath } from "@/features/editor/utils/buffer-index";
import { readFileContent } from "@/features/file-system/controllers/file-operations";
import { usePaneStore } from "@/features/panes/stores/pane.store";
import { activateBufferInPaneAndSync } from "@/features/panes/utils/pane-activation";
import { logger } from "./logger";

let navigationQueue = Promise.resolve();

function waitForEditorActivation(): Promise<void> {
  return new Promise((resolve) => {
    requestAnimationFrame(() => resolve());
  });
}

async function navigateToJumpEntryInternal(entry: JumpListEntry): Promise<boolean> {
  const bufferStore = useBufferStore.getState();

  // Try to find the buffer by ID first, then by path.
  let targetBuffer = getBufferById(bufferStore.buffers, entry.bufferId);

  if (!targetBuffer) {
    targetBuffer = getBufferByPath(bufferStore.buffers, entry.filePath);
  }

  let targetBufferId: string;
  if (!targetBuffer) {
    // Buffer is closed, try to reopen the file.
    try {
      const content = await readFileContent(entry.filePath);
      const fileName = entry.filePath.split("/").pop() || "untitled";
      targetBufferId = bufferStore.actions.openBuffer(entry.filePath, fileName, content);
    } catch (error) {
      logger.error("JumpList", "Failed to reopen file:", entry.filePath, error);
      return false;
    }
  } else {
    targetBufferId = targetBuffer.id;
  }

  const paneActions = usePaneStore.getState().actions;
  const targetPane =
    (entry.paneId ? paneActions.getPaneById(entry.paneId) : paneActions.getActivePane()) ??
    paneActions.getPaneByBufferId(targetBufferId) ??
    paneActions.getActivePane();
  if (!targetPane) return false;

  // A history entry can outlive its source split pane while the buffer remains
  // open in a different pane. Build the owner from the pane actually activated.
  const activatedPaneId = activateBufferInPaneAndSync(targetPane.id, targetBufferId);
  if (!activatedPaneId) return false;

  const targetEditorOwnerId = `${activatedPaneId}:${targetBufferId}`;

  // The active editor adapter is replaced during a buffer switch. Preserve the
  // focus request until the target Monaco surface registers its adapter.
  editorAPI.focusWhenReady(targetEditorOwnerId);

  // Wait for the active Monaco surface to register after a buffer switch.
  await waitForEditorActivation();

  const position = {
    line: entry.line,
    column: entry.column,
    offset: entry.offset,
  };
  let navigationResult = editorAPI.navigateToPositionForOwner(
    targetEditorOwnerId,
    position,
    entry.scrollTop,
    entry.scrollLeft,
  );

  if (navigationResult === "pending") {
    await waitForEditorActivation();
    navigationResult = editorAPI.navigateToPositionForOwner(
      targetEditorOwnerId,
      position,
      entry.scrollTop,
      entry.scrollLeft,
    );
    if (navigationResult === "pending") {
      editorAPI.cancelPendingOwnerNavigation(targetEditorOwnerId);
      return false;
    }
  }

  await waitForEditorActivation();
  editorAPI.focus(targetEditorOwnerId);

  logger.info("JumpList", `Jumped to ${entry.filePath}:${entry.line}:${entry.column}`);

  return true;
}

export function navigateToJumpEntry(entry: JumpListEntry): Promise<boolean> {
  const navigation = navigationQueue.then(async () => {
    const didNavigate = await navigateToJumpEntryInternal(entry);

    return didNavigate;
  });
  navigationQueue = navigation.then(
    () => undefined,
    () => undefined,
  );
  return navigation;
}
