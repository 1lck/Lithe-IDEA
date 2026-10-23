import { listen } from "@tauri-apps/api/event";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { invokeLsp } from "@/platform/lsp-core-adapter";
import { declarativePluginProcessOwner } from "./declarative-plugin-process-owner";
import { normalizeWorkspacePath, pathIsInsideWorkspace } from "./plugin-web-path";

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
      const store = useFileSystemStore.getState();
      const root = store.rootFolderPath;
      if (!root || !pathIsInsideWorkspace(payload.path, root)) return;
      const normalizedPath = normalizeWorkspacePath(payload.path);
      if (!normalizedPath) return;
      void store
        .handleFileSelect(
          normalizedPath,
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

/**
 * Stops declarative run sessions owned by a plugin whose state changed
 * (disable/uninstall) and releases its web-page state.
 */
async function initializePluginLifecycleListener(): Promise<() => void> {
  const unlisten = await listen<{ pluginId: string }>(
    "declarative-plugin-lifecycle",
    ({ payload }) => {
      void Promise.allSettled([
        declarativePluginProcessOwner.stop(undefined, payload.pluginId),
        invokeLsp("lsp_stop_for_provider", { providerId: payload.pluginId }),
      ]);
    },
  );
  return unlisten;
}

/** Registers both plugin-page listeners (open-file and lifecycle). */
export async function initializePluginWebListeners(): Promise<() => void> {
  const unlistenOpen = await initializePluginWebOpenFileListener();
  const unlistenLifecycle = await initializePluginLifecycleListener();
  return () => {
    unlistenOpen();
    unlistenLifecycle();
  };
}
