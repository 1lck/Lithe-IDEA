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
 * `sourceSequence` is Windows' clipboard change counter read when the entries
 * were copied, and `currentSequence` is the same counter read at paste time. A
 * different value proves the clipboard changed after the copy, so whatever the
 * user copied since then wins. Comparing the counter rather than the text is what
 * makes this correct: copying the same string again around a file copy leaves the
 * text identical but the counter different, and only the counter can tell them
 * apart.
 *
 * A zero or missing counter means the platform cannot answer, so the caller keeps
 * the previous behavior and pastes the clipboard text.
 */
export function shouldPasteFileClipboardPaths({
  entryCount,
  sourceSequence,
  currentSequence,
}: {
  entryCount: number;
  sourceSequence: number | null;
  currentSequence: number | null;
}): boolean {
  if (entryCount === 0) return false;
  // The backend reports 0 when the platform has no change counter, so 0 means
  // "unknown" rather than a valid reading. Without a real counter the recency of
  // the copy cannot be judged, and guessing would let stale paths win over text
  // the user copied last.
  if (!sourceSequence || !currentSequence) return false;
  return currentSequence === sourceSequence;
}
