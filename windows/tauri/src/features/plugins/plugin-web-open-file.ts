import { removeDeclarativeUI, refreshDeclarativeUI } from "./declarative-plugin-ui";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { invoke } from "@/platform/tauri-core";
import { assertPluginActive, setPluginActive } from "./declarative-plugin-lifecycle";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { getBufferByPath } from "@/features/editor/utils/buffer-index";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { invokeLsp } from "@/platform/lsp-core-adapter";
import { declarativePluginProcessOwner } from "./declarative-plugin-process-owner";
import { resolvePluginWebFilePath } from "./plugin-web-path";
import { initializePluginWebAppearanceSync } from "./plugin-web-appearance";
import { initializePluginWebBuildListener } from "./plugin-web-build";
import { initializePluginWebFunctionListener } from "./plugin-web-function";

interface PluginWebOpenFilePayload {
  pluginId: string;
  operationId: string;
  workspaceId: string;
  workspacePath: string;
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
    async ({ payload }) => {
      if (!payload?.operationId) return;
      let failure: string | null = null;
      try {
        if (!payload.path) throw new Error("file path is missing");
        const store = useFileSystemStore.getState();
        const root = store.rootFolderPath;
        if (
          !root ||
          payload.workspacePath !== root ||
          payload.workspaceId !== workspaceRuntimeRegistry.getActiveWorkspaceId()
        )
          throw new Error("page workspace is no longer active");
        const resolvedPath = await resolvePluginWebFilePath(payload.path, root);
        if (
          useFileSystemStore.getState().rootFolderPath !== root ||
          payload.workspaceId !== workspaceRuntimeRegistry.getActiveWorkspaceId()
        )
          throw new Error("page workspace changed during file resolution");
        assertPluginActive(payload.pluginId);
        await store.handleFileSelect(
          resolvedPath,
          false,
          payload.line ?? undefined,
          payload.column ?? undefined,
          undefined,
          false,
        );
        if (
          useFileSystemStore.getState().rootFolderPath !== root ||
          payload.workspaceId !== workspaceRuntimeRegistry.getActiveWorkspaceId()
        )
          throw new Error("page workspace changed while opening the file");
        const editor = useBufferStore.getStore(payload.workspaceId).getState();
        const opened = getBufferByPath(editor.buffers, resolvedPath);
        // The shared file-open handler also resolves after a stale request or
        // a read error, so its promise alone cannot acknowledge success.
        if (!opened || editor.activeBufferId !== opened.id)
          throw new Error("the editor did not open the requested file");
      } catch (error) {
        failure = String(error);
      }
      await invoke("declarative_plugins_web_open_file_ack", {
        operationId: payload.operationId,
        error: failure,
      });
    },
    { target: { kind: "Window", label: getCurrentWindow().label } },
  );
  return unlisten;
}

/**
 * Stops declarative run sessions owned by a plugin whose state changed
 * (disable/uninstall) and releases its web-page state.
 */
async function initializePluginLifecycleListener(): Promise<() => void> {
  const unlisten = await listen<{ pluginId: string; active: boolean; operationId?: string }>(
    "declarative-plugin-lifecycle",
    async ({ payload }) => {
      setPluginActive(payload.pluginId, payload.active);
      if (!payload.active) removeDeclarativeUI(payload.pluginId);
      else await refreshDeclarativeUI();
      if (!payload.operationId) return;
      const outcomes = await Promise.allSettled([
        declarativePluginProcessOwner.stop(undefined, payload.pluginId),
        invokeLsp("lsp_stop_for_provider", { providerId: payload.pluginId }),
      ]);
      const failure = outcomes.find((outcome) => outcome.status === "rejected");
      await invoke("declarative_plugins_lifecycle_ack", {
        operationId: payload.operationId,
        error: failure?.status === "rejected" ? String(failure.reason) : null,
      });
    },
    // Tauri's default Any target also receives events emitted to other labels.
    // Each product window must drain and acknowledge only its own event.
    { target: { kind: "Window", label: getCurrentWindow().label } },
  );
  return unlisten;
}

/** Registers the workbench-owned plugin page listeners. */
export async function initializePluginWebListeners(): Promise<() => void> {
  const cleanups: Array<() => void> = [];
  try {
    cleanups.push(await initializePluginWebOpenFileListener());
    cleanups.push(await initializePluginLifecycleListener());
    cleanups.push(await initializePluginWebBuildListener());
    cleanups.push(await initializePluginWebFunctionListener());
    cleanups.push(initializePluginWebAppearanceSync());
    return () => {
      for (const cleanup of cleanups.splice(0).reverse()) cleanup();
    };
  } catch (error) {
    for (const cleanup of cleanups.reverse()) cleanup();
    throw error;
  }
}
