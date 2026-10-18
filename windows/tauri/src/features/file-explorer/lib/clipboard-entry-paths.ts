/**
 * Paths to insert for copied explorer entries.
 *
 * They stay absolute. A relative path only resolves correctly against the shell's
 * live directory, and on Windows neither cmd nor PowerShell reports that
 * directory (no OSC 7), so the tracked value is just the launch directory and
 * goes stale as soon as the user runs `cd`. An absolute path is correct wherever
 * the shell currently is, and it also expresses the copied directory itself,
 * which a relative path would render as an empty string.
 */
export function clipboardEntryPaths(entries: readonly { path: string }[]): string[] {
  return entries.map((entry) => entry.path).filter((path) => path.length > 0);
}

/**
 * Decide whether a terminal paste should insert the copied file paths instead
 * of the system clipboard text.
 *
 * `sourceClipboardText` is the system clipboard text observed when the entries
 * were copied. If the clipboard now holds anything else, the user copied text
 * after copying files, so the text wins; this keeps the terminal from silently
 * ignoring what the user copied most recently.
 *
 * Copying the exact same string again around a file copy is indistinguishable
 * from not copying at all, because the Tauri clipboard plugin exposes no change
 * counter; that path inserts the file paths. Keeping the automatic behavior is a
 * deliberate trade-off: inserting paths is what the user asked the copy to be
 * good for, the false case needs the same content twice with a file copy between,
 * and its cost is a visible, harmless insertion the user can undo by pasting
 * again. Dropping the automatic case instead would add a manual step to every
 * copy-to-terminal, and removing it would need an OS change counter the plugin
 * does not provide. The terminal also offers an explicit "paste file paths"
 * action for callers that must not guess.
 */
export function shouldPasteFileClipboardPaths({
  entryCount,
  sourceClipboardText,
  currentClipboardText,
}: {
  entryCount: number;
  sourceClipboardText: string | null;
  currentClipboardText: string;
}): boolean {
  if (entryCount === 0) return false;
  // Without a recorded snapshot the recency of the copy is unknown, so keep the
  // previous behavior and paste the clipboard text.
  if (sourceClipboardText === null) return false;
  return currentClipboardText === sourceClipboardText;
}
