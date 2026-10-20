/**
 * The system file chooser for the composer's "Attach files" action, the
 * counterpart of the macOS `.fileImporter` with multiple selection.
 *
 * Kept apart from the pure composer logic so tests never import the Tauri
 * dialog plugin.
 */

import { open } from "@tauri-apps/plugin-dialog";

/** Absolute paths the user picked, or an empty list when they cancelled. */
export async function chooseAgentFiles(): Promise<string[]> {
  const selected = await open({ directory: false, multiple: true });
  if (selected === null) return [];
  return Array.isArray(selected) ? selected : [selected];
}
