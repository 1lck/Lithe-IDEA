import { listen } from "@tauri-apps/api/event";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";

interface PluginWebOpenFilePayload {
  pluginId: string;
  path: string | null;
  line: number | null;
  column: number | null;
}

/**
 * Handles `workspace.openFile` bridge requests from plugin web pages. The
 * Rust bridge authorizes the calling page's plugin; this listener routes the
 * request into the workspace's canonical file-open entry and confines the
 * path to the open workspace root (the bridge contract only allows paths
 * inside the workspace).
 */
export async function initializePluginWebOpenFileListener(): Promise<() => void> {
  const unlisten = await listen<PluginWebOpenFilePayload>(
    "plugin-web-open-file",
    ({ payload }) => {
      if (!payload?.path) return;
      const workspaceId = workspaceRuntimeRegistry.getActiveWorkspaceId();
      const store = useFileSystemStore.getState();
      const root = store.rootFolderPath;
      if (!root || !pathIsInsideWorkspace(payload.path, root)) return;
      void store
        .handleFileSelect(
          payload.path,
          false,
          payload.line ?? undefined,
          payload.column ?? undefined,
          undefined,
          false,
        )
        .catch(() => {
          // A failed open is reported by the store's own error surface; the
          // page only gets an ack either way.
        });
    },
  );
  return unlisten;
}

function pathIsInsideWorkspace(path: string, root: string): boolean {
  const normalized = path.replace(/\\/g, "/");
  const normalizedRoot = root.replace(/\\/g, "/").replace(/\/$/, "");
  if (normalized.toLowerCase() === normalizedRoot.toLowerCase()) return false;
  return normalized.toLowerCase().startsWith(`${normalizedRoot.toLowerCase()}/`);
}
