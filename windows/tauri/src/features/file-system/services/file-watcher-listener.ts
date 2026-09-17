import { initializeDocumentWatches, cleanupDocumentWatches } from "@/features/editor/services/document-watch-controller";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { dirname } from "@tauri-apps/api/path";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { useMavenStore } from "@/features/maven/stores/maven.store";
import { getBaseName, getRelativePath, pathStartsWithRoot } from "@/utils/path-helpers";
import { useFileTreeStore } from "@/features/file-explorer/stores/file-explorer-tree.store";
import { useFileSystemStore } from "../stores/file-system.store";
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
  event_type: "opened" | "reloaded" | "deleted" | "rescan";
}

let unlistenFileChanged: UnlistenFn | null = null;

export function getMavenPomChangePath(
  path: string,
  rootFolderPath: string | undefined,
): string | null {
  if (
    !rootFolderPath ||
    !pathStartsWithRoot(path, rootFolderPath) ||
    getBaseName(path).toLowerCase() !== "pom.xml"
  ) {
    return null;
  }
  return getRelativePath(path, rootFolderPath);
}

export function getWorkspaceRootForChange(
  path: string,
  rootFolderPath: string | undefined,
  workspaceFolderPaths: readonly string[],
): string | null {
  const roots = new Set(workspaceFolderPaths);
  if (rootFolderPath) roots.add(rootFolderPath);

  return (
    [...roots]
      .filter((root) => pathStartsWithRoot(path, root))
      .sort((left, right) => right.length - left.length)[0] ?? null
  );
}

function scheduleDirectoryRefresh(workspaceId: string, directoryPath: string) {
  scheduleFileWatcherRefresh(workspaceId, directoryPath, async () => {
    if (!workspaceRuntimeRegistry.hasWorkspace(workspaceId)) {
      return;
    }

    await useFileSystemStore
      .getStore(workspaceId)
      .getState()
      .refreshDirectory(directoryPath, { force: true });
  });
}

function scheduleWorkspaceRescan(workspaceId: string, workspaceRoot: string) {
  scheduleFileWatcherRefresh(workspaceId, `rescan:${workspaceRoot}`, async () => {
    if (!workspaceRuntimeRegistry.hasWorkspace(workspaceId)) {
      return;
    }

    const refreshDirectory = useFileSystemStore.getStore(workspaceId).getState().refreshDirectory;
    const expandedPaths = [
      ...useFileTreeStore.getStore(workspaceId).getState().actions.getExpandedPaths(),
    ].filter((path) => pathStartsWithRoot(path, workspaceRoot));
    const directories = [...new Set([workspaceRoot, ...expandedPaths])].sort(
      (left, right) => left.length - right.length,
    );
    for (const directoryPath of directories) {
      await refreshDirectory(directoryPath, { force: true });
    }
  });
}

export async function initializeFileWatcherListener() {
  await cleanupFileWatcherListener();
  await initializeDocumentWatches();

  unlistenFileChanged = await listen<FileChangeEvent>("file-changed", async (event) => {
    const { path, event_type } = event.payload;
    const workspaceId = workspaceRuntimeRegistry.getActiveWorkspaceId();
    const fileSystemState = useFileSystemStore.getStore(workspaceId).getState();
    const rootFolderPath = fileSystemState.rootFolderPath;
    const workspaceRoot = getWorkspaceRootForChange(
      path,
      rootFolderPath,
      fileSystemState.workspaceFolders.map((folder) => folder.path),
    );
    if (!rootFolderPath || !workspaceRoot) return;

    if (event_type === "rescan") {
      scheduleWorkspaceRescan(workspaceId, workspaceRoot);
      return;
    }

    const parentDirectory = await dirname(path);
    const mavenPomPath = getMavenPomChangePath(path, workspaceRoot);

    window.dispatchEvent(
      new CustomEvent("file-external-change", {
        detail: { path, event_type },
      }),
    );

    if (mavenPomPath !== null) {
      useMavenStore.getStore(workspaceId).getState().actions.markPomReloadRequired(mavenPomPath);
    } else {
      scheduleJavaWorkspaceChange(workspaceId, workspaceRoot, {
        path,
        kind: event_type === "deleted" ? "deleted" : event_type === "opened" ? "created" : "changed",
        includeSource: true,
      });
    }

    if (event_type === "deleted" || event_type === "opened") {
      scheduleDirectoryRefresh(workspaceId, parentDirectory);
      return;
    }
  });
}

export async function cleanupFileWatcherListener() {
  await cleanupDocumentWatches();
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
