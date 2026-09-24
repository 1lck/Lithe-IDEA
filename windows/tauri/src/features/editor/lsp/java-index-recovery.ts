import { LspClient } from "./lsp-client";
import { resolveJavaLspLaunch } from "./java-lsp-host-api";
import { invoke } from "@/platform/tauri-core";

/** Stops one Java workspace and removes only its validated JDT state directory. */
export async function rebuildJavaIndexForWorkspace(workspacePath: string): Promise<void> {
  const launch = await resolveJavaLspLaunch(workspacePath);
  // The running server holds the index directory open on Windows, so it has to
  // exit before the native adapter can remove the workspace state.
  await LspClient.getInstance().stop(workspacePath);
  await invoke("lsp_rebuild_java_index", {
    workspacePath,
    workspaceFingerprint: launch.workspaceFingerprint ?? null,
  });
}
