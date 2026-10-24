import { invoke } from "@/platform/tauri-core";

/** The native host resolves every path component, including directory junctions. */
export function resolvePluginWebFilePath(path: string, workspacePath: string): Promise<string> {
  return invoke<string>("declarative_plugins_web_resolve_file", { path, workspacePath });
}
