import { editorAPI } from "@/features/editor/extensions/api";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import type { JumpListEntry } from "@/features/editor/stores/jump-list.store";
import { useEditorStateStore } from "@/features/editor/stores/state.store";
import { getBufferById, getBufferByPath } from "@/features/editor/utils/buffer-index";
import { readFileContent } from "@/features/file-system/controllers/file-operations";
import { logger } from "./logger";

let navigationQueue = Promise.resolve();

function waitForEditorActivation(): Promise<void> {
  return new Promise((resolve) => {
    requestAnimationFrame(() => resolve());
  });
}

async function navigateToJumpEntryInternal(entry: JumpListEntry): Promise<boolean> {
  const bufferStore = useBufferStore.getState();

  // Try to find the buffer by ID first, then by path
  let targetBuffer = getBufferById(bufferStore.buffers, entry.bufferId);

  if (!targetBuffer) {
    targetBuffer = getBufferByPath(bufferStore.buffers, entry.filePath);
  }

  if (!targetBuffer) {
    // Buffer is closed, try to reopen the file
    try {
      const content = await readFileContent(entry.filePath);
      const fileName = entry.filePath.split("/").pop() || "untitled";
      const bufferId = bufferStore.actions.openBuffer(entry.filePath, fileName, content);
      bufferStore.actions.setActiveBuffer(bufferId);
    } catch (error) {
      logger.error("JumpList", "Failed to reopen file:", entry.filePath, error);
      return false;
    }
  } else {
    bufferStore.actions.setActiveBuffer(targetBuffer.id);
  }

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

export function navigateToJumpEntry(entry: JumpListEntry): Promise<boolean> {
  const navigation = navigationQueue.then(() => navigateToJumpEntryInternal(entry));
  navigationQueue = navigation.then(
    () => undefined,
    () => undefined,
  );
  return navigation;
}
