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
 * Comparing text cannot detect copying the same string again around a file copy,
 * because the Tauri clipboard plugin exposes no change counter. The terminal also
 * offers an explicit "paste file paths" action that skips this check.
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
