import { getRelativePath } from "@/utils/path-helpers";

/**
 * Render copied explorer entries as path tokens a terminal can accept.
 *
 * `baseDirectory` must be the directory the target shell is in, not the workspace
 * root: a terminal opened on a subdirectory, or one the user changed directory
 * in, resolves a workspace-relative path to the wrong file. Callers that cannot
 * determine that directory pass `null` and get full paths.
 *
 * Tokens are returned separately rather than pre-joined: the terminal has to
 * quote each one before joining so a path containing spaces stays one argument.
 */
export function clipboardEntryPaths(
  entries: readonly { path: string }[],
  baseDirectory?: string | null,
): string[] {
  return entries
    .map((entry) => getRelativePath(entry.path, baseDirectory))
    .filter((path) => path.length > 0);
}

/**
 * Decide whether a terminal paste should insert the copied file paths instead
 * of the system clipboard text.
 *
 * `sourceClipboardText` is the system clipboard text observed when the entries
 * were copied. If the clipboard now holds anything else, the user copied text
 * after copying files, so the text wins; this keeps the terminal from silently
 * ignoring what the user copied most recently.
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
