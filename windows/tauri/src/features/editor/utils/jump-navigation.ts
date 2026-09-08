import { editorAPI } from "@/features/editor/extensions/api";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import type { JumpListEntry } from "@/features/editor/stores/jump-list.store";
import { useEditorStateStore } from "@/features/editor/stores/state.store";
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

async function navigateToJumpEntryInternal(
  entry: JumpListEntry,
  requestedPaneId?: string,
): Promise<boolean> {
  const bufferStore = useBufferStore.getState();
  const paneId = requestedPaneId ?? entry.paneId ?? usePaneStore.getState().activePaneId;

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

  // Keep the navigation in the triggering pane even when another pane contains
  // the same buffer. The global active-buffer sync otherwise selects the first
  // matching pane and can move a right-pane navigation back to the left pane.
  activateBufferInPaneAndSync(paneId, targetBufferId);

  // The active editor adapter is replaced during a buffer switch. Preserve the
  // focus request until the target Monaco surface registers its adapter.
  editorAPI.focusWhenReady();

  // Wait for the active Monaco surface to register after a buffer switch.
  await waitForEditorActivation();

  editorAPI.clearSelectionForNavigation();
  editorAPI.setCursorPosition({
    line: entry.line,
    column: entry.column,
    offset: entry.offset,
  });

  useEditorStateStore.getState().actions.setScroll(entry.scrollTop, entry.scrollLeft);
  editorAPI.focus();

  // Cursor/state updates can trigger another render; focus again after it so
  // repeated history shortcuts keep the editor as the active input target.
  await waitForEditorActivation();
  editorAPI.focus();

  logger.info("JumpList", `Jumped to ${entry.filePath}:${entry.line}:${entry.column}`);

  return true;
}

export function navigateToJumpEntry(entry: JumpListEntry, paneId?: string): Promise<boolean> {
  const navigation = navigationQueue.then(() => navigateToJumpEntryInternal(entry, paneId));
  navigationQueue = navigation.then(
    () => undefined,
    () => undefined,
  );
  return navigation;
}
