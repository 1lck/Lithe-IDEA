import { stat } from "@tauri-apps/plugin-fs";
import { invoke } from "./tauri-core";

export function readAgentClipboardFiles(): Promise<string[]> {
  return invoke("agent_clipboard_file_paths");
}

/** Metadata only: attaching a reference never reads or saves an editor buffer. */
export async function isAgentLocalFile(path: string): Promise<boolean> {
  try {
    return (await stat(path)).isFile;
  } catch {
    return false;
  }
}
