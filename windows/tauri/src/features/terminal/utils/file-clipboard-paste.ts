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
 * `currentDirectory` is the target shell's directory, which decides what a
 * relative path resolves to. When it is unknown the paths stay absolute.
 */
async function fileClipboardPasteText(currentDirectory: string | null): Promise<string | null> {
  const { clipboard, sourceClipboardText } = useFileClipboardStore.getState();
  const entries = clipboard?.entries ?? [];
  if (entries.length === 0) return null;

  let currentClipboardText: string;
  try {
    currentClipboardText = await readClipboardText();
  } catch {
    // An unreadable clipboard cannot prove the file copy is still the latest
    // user action, so fall back instead of guessing.
    return null;
  }

  const prefersFilePaths = shouldPasteFileClipboardPaths({
    entryCount: entries.length,
    sourceClipboardText,
    currentClipboardText,
  });
  if (!prefersFilePaths) return null;

  const paths = clipboardEntryPaths(entries, currentDirectory);
  if (paths.length === 0) return null;
  return quoteTerminalPaths(paths);
}

/**
 * Resolve what a terminal paste should insert: the copied explorer paths when
 * that copy is still the user's latest action, otherwise the clipboard text.
 */
export async function readTerminalPasteText(
  currentDirectory?: string | null,
): Promise<string> {
  const filePaths = await fileClipboardPasteText(currentDirectory ?? null);
  if (filePaths !== null) return filePaths;
  return readClipboardText();
}
