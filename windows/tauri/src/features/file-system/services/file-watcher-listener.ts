import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { dirname } from "@tauri-apps/api/path";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { getBufferByPath } from "@/features/editor/utils/buffer-index";
import { emitGitChanged } from "@/features/git/events/git-events";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { useFileSystemStore } from "../stores/file-system.store";
import { useFileWatcherStore } from "../stores/file-watcher.store";
import {
  cancelFileWatcherRefreshes,
  scheduleFileWatcherRefresh,
} from "./file-watcher-refresh-scheduler";
import {
  cancelJavaWorkspaceChanges,
  scheduleJavaWorkspaceChange,
} from "@/features/editor/lsp/java-workspace-change-scheduler";

interface FileChangeEvent {
  path: string;
  event_type: "opened" | "reloaded" | "deleted";
}

let unlistenFileChanged: UnlistenFn | null = null;

function scheduleDirectoryRefresh(workspaceId: string, directoryPath: string) {
  scheduleFileWatcherRefresh(workspaceId, directoryPath, async () => {
    if (!workspaceRuntimeRegistry.hasWorkspace(workspaceId)) {
      return;
    }

    await useFileSystemStore.getStore(workspaceId).getState().refreshDirectory(directoryPath);
  });
}

export async function initializeFileWatcherListener() {
  await cleanupFileWatcherListener();

  unlistenFileChanged = await listen<FileChangeEvent>("file-changed", async (event) => {
    const { path, event_type } = event.payload;
    const workspaceId = workspaceRuntimeRegistry.getActiveWorkspaceId();
    const rootFolderPath = useFileSystemStore.getStore(workspaceId).getState().rootFolderPath;
    const parentDirectory = await dirname(path);

    window.dispatchEvent(
      new CustomEvent("file-external-change", {
        detail: { path, event_type },
      }),
    );

    const pendingSave = useFileWatcherStore
      .getStore(workspaceId)
      .getState().pendingSaves.has(path);
    if (rootFolderPath) {
      scheduleJavaWorkspaceChange(workspaceId, rootFolderPath, {
        path,
        kind: event_type === "deleted" ? "deleted" : event_type === "opened" ? "created" : "changed",
        includeSource: !pendingSave,
      });
    }

    if (event_type === "deleted" || event_type === "opened") {
      scheduleDirectoryRefresh(workspaceId, parentDirectory);
      return;
    }

    const fileWatcherState = useFileWatcherStore.getStore(workspaceId).getState();
    if (pendingSave) {
      return;
    }

    const bufferState = useBufferStore.getStore(workspaceId).getState();
    const buffer = getBufferByPath(bufferState.buffers, path);
    if (!buffer) {
      return;
    }

    const result = await bufferState.actions.handleExternalBufferChange(
      buffer.id,
      crypto.randomUUID(),
    );
    if (result === "reloaded") {
      window.dispatchEvent(new CustomEvent("file-reloaded", { detail: { path } }));
    }
    if (result === "failed" || result === "ignored") {
      return;
    }
    emitGitChanged({
      filePath: path,
      scopes: ["working-tree"],
      source: "external-file-change",
    });
  });
}

export async function cleanupFileWatcherListener() {
  cancelFileWatcherRefreshes();
  cancelJavaWorkspaceChanges();

  if (!unlistenFileChanged) {
    return;
  }

  try {
    unlistenFileChanged();
  } catch (error) {
    console.error("Error cleaning up file change listener:", error);
  }
  unlistenFileChanged = null;
}
