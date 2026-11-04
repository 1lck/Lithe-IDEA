import { canUseNativeFileSearch } from "@/features/file-search/utils/file-search-paths";
import { subscribeToGitChanges, isGitChangeRelevant } from "@/features/git/events/git-events";
import {
  configureWorkspaceIndexing,
  indexingRefreshedEvent,
} from "@/features/file-explorer/stores/workspace-indexing";
import {
  initializeDocumentWatches,
  cleanupDocumentWatches,
} from "@/features/editor/services/document-watch-controller";
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

type FileChangeType = "opened" | "reloaded" | "deleted" | "rescan";

interface FileChangeEvent {
  path: string;
  event_type: FileChangeType;
}

let unlistenFileChanged: UnlistenFn | null = null;
let unlistenGitChanged: (() => void) | undefined;
let unlistenIndexingRefreshed: UnlistenFn | undefined;
let removeFocusListener: (() => void) | undefined;
const MAX_PENDING_REFRESH_DIRECTORIES = 128;

export interface PendingWorkspaceRefresh {
  directories: Set<string>;
  fullRescan: boolean;
}

const pendingWorkspaceRefreshes = new Map<string, PendingWorkspaceRefresh>();

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

export function getFileTreeRefreshRequest(
  eventType: FileChangeType,
  workspaceRoot: string,
  parentDirectory?: string,
): { fullRescan: boolean; directoryPath?: string } | null {
  if (eventType === "rescan") return { fullRescan: true };
  if (eventType !== "opened" && eventType !== "deleted") return null;
  if (!parentDirectory || !pathStartsWithRoot(parentDirectory, workspaceRoot)) {
    return { fullRescan: true };
  }
  return { fullRescan: false, directoryPath: parentDirectory };
}

export function updatePendingWorkspaceRefresh(
  pending: PendingWorkspaceRefresh,
  workspaceRoot: string,
  directoryPath?: string,
  maxDirectories = MAX_PENDING_REFRESH_DIRECTORIES,
): void {
  if (!directoryPath || !pathStartsWithRoot(directoryPath, workspaceRoot)) {
    pending.fullRescan = true;
    pending.directories.clear();
    return;
  }
  if (pending.fullRescan) return;

  pending.directories.add(directoryPath);
  if (pending.directories.size > maxDirectories) {
    pending.fullRescan = true;
    pending.directories.clear();
  }
}

function workspaceRefreshKey(workspaceId: string, workspaceRoot: string): string {
  return `${workspaceId}\0${workspaceRoot}`;
}

function scheduleWorkspaceRefresh(
  workspaceId: string,
  workspaceRoot: string,
  directoryPath?: string,
) {
  const runtime = workspaceRuntimeRegistry.getWorkspace(workspaceId);
  if (!runtime) return;
  const key = workspaceRefreshKey(workspaceId, workspaceRoot);
  const pending = pendingWorkspaceRefreshes.get(key) ?? {
    directories: new Set<string>(),
    fullRescan: false,
  };
  updatePendingWorkspaceRefresh(pending, workspaceRoot, directoryPath);
  pendingWorkspaceRefreshes.set(key, pending);

  scheduleFileWatcherRefresh(workspaceId, `workspace:${workspaceRoot}`, async () => {
    const refresh = pendingWorkspaceRefreshes.get(key);
    pendingWorkspaceRefreshes.delete(key);
    if (workspaceRuntimeRegistry.getWorkspace(workspaceId) !== runtime) {
      return;
    }

    const refreshDirectory = useFileSystemStore.getStore(workspaceId).getState().refreshDirectory;
    const directories = new Set(refresh?.directories ?? []);
    if (refresh?.fullRescan) {
      directories.add(workspaceRoot);
      for (const path of useFileTreeStore
        .getStore(workspaceId)
        .getState()
        .actions.getExpandedPaths()) {
        if (pathStartsWithRoot(path, workspaceRoot)) directories.add(path);
      }
    }
    const orderedDirectories = [...directories].sort((left, right) => left.length - right.length);
    for (const directoryPath of orderedDirectories) {
      await refreshDirectory(directoryPath, { force: true });
    }
  });
}

export async function initializeFileWatcherListener() {
  await cleanupFileWatcherListener();
  await initializeDocumentWatches();
  unlistenIndexingRefreshed = await listen<string>("workspace-indexing-refreshed", ({payload}) => {
    window.dispatchEvent(new window.CustomEvent(indexingRefreshedEvent, {detail: payload}));
  });
  const focus = () => {
    for (const runtime of workspaceRuntimeRegistry.getWorkspaces()) runtime.invalidateIndexing?.();
  };
  window.addEventListener("focus", focus);
  removeFocusListener = () => window.removeEventListener("focus", focus);
  unlistenGitChanged = subscribeToGitChanges((change) => {
    // Native batches have already invalidated the shared root before being broadcast.
    if (["save", "auto-save", "external-file-change", "external-git-change"].includes(change.source ?? "")) return;
    for (const runtime of workspaceRuntimeRegistry.getWorkspaces()) {
      const store = runtime.stores.get("file-system");
      if (!store) continue;
      const workspaceId = runtime.descriptor.id;
      const state = useFileSystemStore.getStore(workspaceId).getState();
      const roots = new Set([state.rootFolderPath, ...state.workspaceFolders.map((folder) => folder.path)]);
      for (const root of roots) {
        if (!canUseNativeFileSearch(root) || !isGitChangeRelevant(change, root)) continue;
        // Queue synchronously so a query from the same action cannot overtake invalidation.
        void configureWorkspaceIndexing(root, [], true, workspaceId).catch(console.error);
      }
    }
  });

  unlistenFileChanged = await listen<FileChangeEvent>("file-changed", async (event) => {
    const { path, event_type } = event.payload;
    const targets = workspaceRuntimeRegistry.getWorkspaces().filter((runtime) => runtime.stores.has("file-system"));
    window.dispatchEvent(new window.CustomEvent("file-external-change", {detail: {path, event_type}}));
    await Promise.all(targets.map(async (runtime) => {
      const workspaceId = runtime.descriptor.id;
      const isCurrent = () => workspaceRuntimeRegistry.getWorkspace(workspaceId) === runtime;
      const fileSystemState = useFileSystemStore.getStore(workspaceId).getState();
      const rootFolderPath = fileSystemState.rootFolderPath;
      const workspaceRoot = getWorkspaceRootForChange(
        path,
        rootFolderPath,
        fileSystemState.workspaceFolders.map((folder) => folder.path),
      );
      if (!rootFolderPath || !workspaceRoot) return;

      if (event_type === "rescan") {
        const refreshRequest = getFileTreeRefreshRequest(event_type, workspaceRoot);
        if (refreshRequest) scheduleWorkspaceRefresh(workspaceId, workspaceRoot);
        return;
      }

      const parentDirectory = await dirname(path);
      if (!isCurrent()) return;
      const mavenPomPath = getMavenPomChangePath(path, workspaceRoot);

      const parentRelative =
        getRelativePath(parentDirectory, workspaceRoot).replace(/\\/g, "/") || ".";
      let excluded: boolean | undefined = false;
      if (canUseNativeFileSearch(workspaceRoot)) {
        try {
          const policy = await configureWorkspaceIndexing(workspaceRoot, [parentRelative], false, workspaceId);
          excluded = Object.keys(policy.excludedDirectories).some(
            (directory) =>
              directory === "." ||
              parentRelative === directory ||
              parentRelative.startsWith(directory + "/"),
          );
        } catch (error) {
          // Indexing failures must not suppress tree updates or Maven reload state.
          // Defer source notifications until the exclusion policy is known.
          excluded = undefined;
          console.error("Failed to read workspace indexing policy for file change:", error);
        }
      }
      if (!isCurrent()) return;
      const currentState = useFileSystemStore.getStore(workspaceId).getState();
      if (getWorkspaceRootForChange(path, currentState.rootFolderPath, currentState.workspaceFolders.map((folder) => folder.path)) !== workspaceRoot) return;
      if (mavenPomPath !== null) {
        useMavenStore.getStore(workspaceId).getState().actions.markPomReloadRequired(mavenPomPath);
      } else if (excluded === false) {
        scheduleJavaWorkspaceChange(workspaceId, workspaceRoot, {
          path,
          kind:
            event_type === "deleted" ? "deleted" : event_type === "opened" ? "created" : "changed",
          includeSource: true,
        });
      }

      const refreshRequest = getFileTreeRefreshRequest(event_type, workspaceRoot, parentDirectory);
      if (refreshRequest) {
        scheduleWorkspaceRefresh(
          workspaceId,
          workspaceRoot,
          refreshRequest.fullRescan ? undefined : refreshRequest.directoryPath,
        );
        return;
      }
    }));
  });
}

export async function cleanupFileWatcherListener() {
  unlistenGitChanged?.();
  unlistenGitChanged = undefined;
  unlistenIndexingRefreshed?.(); unlistenIndexingRefreshed = undefined;
  removeFocusListener?.(); removeFocusListener = undefined;
  await cleanupDocumentWatches();
  cancelFileWatcherRefreshes();
  pendingWorkspaceRefreshes.clear();
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
