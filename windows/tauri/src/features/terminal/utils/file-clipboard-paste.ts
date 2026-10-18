import { invoke } from "@/platform/tauri-core";
import {
  clipboardEntryPaths,
  shouldPasteFileClipboardPaths,
} from "@/features/file-explorer/lib/clipboard-entry-paths";
import { useFileClipboardStore } from "@/features/file-explorer/stores/file-explorer-clipboard.store";
import { readClipboardText } from "@/utils/clipboard";
import { quoteTerminalPaths } from "./terminal-file-drop";

/**
 * Build the terminal insertion text for the file or directory copied in the
 * project explorer, or null when the system clipboard text should be used.
 *
 * Copying files in the explorer only fills the in-app clipboard, which no other
 * application can read. Translating it here means pasting keeps working for the
 * user without the copy having to overwrite the system clipboard.
 *
 * When `allowStale` is true the clipboard-recency check is skipped, so the caller
 * can offer an explicit action that always pastes the copied paths.
 */
async function fileClipboardPasteText(
  shell: string | null,
  allowStale: boolean,
): Promise<string | null> {
  const { clipboard, sourceClipboardSequence } = useFileClipboardStore.getState();
  const entries = clipboard?.entries ?? [];
  if (entries.length === 0) return null;

  if (!allowStale) {
    let currentSequence: number | null;
    try {
      currentSequence = await invoke<number>("clipboard_sequence_number");
    } catch {
      // Without the counter the recency of the copy is unknown, so fall back
      // instead of guessing.
      return null;
    }

    const prefersFilePaths = shouldPasteFileClipboardPaths({
      entryCount: entries.length,
      sourceSequence: sourceClipboardSequence,
      currentSequence,
    });
    if (!prefersFilePaths) return null;
  }

  const paths = clipboardEntryPaths(entries);
  if (paths.length === 0) return null;
  return quoteTerminalPaths(paths, shell);
}

/**
 * Resolve what a terminal paste should insert: the copied explorer paths when
 * that copy is still the user's latest action, otherwise the clipboard text.
 */
export async function readTerminalPasteText(shell?: string | null): Promise<string> {
  const filePaths = await fileClipboardPasteText(shell ?? null, false);
  if (filePaths !== null) return filePaths;
  return readClipboardText();
}

/**
 * Resolve the copied explorer paths unconditionally, for an explicit action that
 * must not depend on guessing which copy came last. Returns null when the in-app
 * file clipboard is empty.
 */
export async function readCopiedFilePathsText(shell?: string | null): Promise<string | null> {
  return fileClipboardPasteText(shell ?? null, true);
}
