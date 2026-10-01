/**
 * Writes an exported transcript to a file the user picks.
 *
 * The destination is always chosen in a native save dialog and the only write
 * target is the returned path, so an export can never land in an installed
 * bundle. Labels arrive already translated; platform errors are not shown raw.
 */

import { save } from "@tauri-apps/plugin-dialog";
import { writeTextFile } from "@tauri-apps/plugin-fs";

/** macOS writes at most 32 MiB per export; Windows holds the same bound. */
export const HISTORY_EXPORT_LIMIT_BYTES = 32 * 1024 * 1024;

export class AgentHistoryExportError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "AgentHistoryExportError";
  }
}

export interface AgentHistorySaveLabels {
  title: string;
  fileType: string;
  tooLarge: string;
  failed: string;
}

/**
 * Ask for a destination and write the transcript there.
 *
 * Returns false when the user cancelled the dialog, so a cancelled export
 * neither writes nor reports an error.
 */
export async function saveHistoryMarkdown(
  markdown: string,
  labels: AgentHistorySaveLabels,
): Promise<boolean> {
  if (new TextEncoder().encode(markdown).length > HISTORY_EXPORT_LIMIT_BYTES) {
    throw new AgentHistoryExportError(labels.tooLarge);
  }
  let destination: string | null;
  try {
    destination = await save({
      title: labels.title,
      defaultPath: "agent-conversations.md",
      filters: [{ name: labels.fileType, extensions: ["md"] }],
    });
  } catch {
    throw new AgentHistoryExportError(labels.failed);
  }
  if (destination === null) return false;
  try {
    await writeTextFile(destination, markdown);
  } catch {
    throw new AgentHistoryExportError(labels.failed);
  }
  return true;
}
