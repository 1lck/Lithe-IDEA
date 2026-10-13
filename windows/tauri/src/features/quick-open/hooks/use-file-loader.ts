import { useEffect, useMemo, useRef, useState } from "react";
import { type FffIndexedFile, fffListFiles } from "@/features/file-search/lib/file-search-api";
import { getNativeWorkspaceRootPaths } from "@/features/file-search/utils/file-search-paths";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import type { FileItem } from "../types/quick-open.types";

// Keep the complete snapshot: the switcher-only ignore list is applied by useFileSearch for empty
// queries so an explicit filename search can still reach files such as .gitignore or Cargo.lock.
const toQuickOpenFiles = (files: readonly Pick<FffIndexedFile, "name" | "path">[]): FileItem[] =>
  files.map((file) => ({
    name: file.name,
    path: file.path,
    isDir: false,
  }));

export const useFileLoader = (isVisible: boolean) => {
  const getAllProjectFiles = useFileSystemStore((state) => state.getAllProjectFiles);
  const rootFolderPath = useFileSystemStore((state) => state.rootFolderPath);
  const workspaceFolders = useFileSystemStore((state) => state.workspaceFolders);
  const nativeRootPaths = useMemo(
    () => getNativeWorkspaceRootPaths(rootFolderPath, workspaceFolders),
    [rootFolderPath, workspaceFolders],
  );
  const workspaceKey = JSON.stringify([
    rootFolderPath,
    workspaceFolders.map((folder) => folder.path),
  ]);
  const [files, setFiles] = useState<FileItem[]>([]);
  const [isLoadingFiles, setIsLoadingFiles] = useState(false);
  const [isIndexing, setIsIndexing] = useState(false);
  const loadedForRootRef = useRef<string | null>(null);

  useEffect(() => {
    if (!isVisible) return;

    let cancelled = false;

    const loadFiles = async () => {
      if (loadedForRootRef.current !== workspaceKey) {
        setFiles([]);
      }
      setIsLoadingFiles(true);
      setIsIndexing(nativeRootPaths.length > 0);

      try {
        // The Core adapter returns a complete snapshot, not a background index.
        // Refresh once per opening; typing searches this list without rescanning.
        const allFiles =
          nativeRootPaths.length > 0
            ? await fffListFiles(nativeRootPaths)
            : (await getAllProjectFiles()).filter((file) => !file.isDir);
        if (cancelled) return;
        loadedForRootRef.current = workspaceKey;
        setFiles(toQuickOpenFiles(allFiles));
      } catch (error) {
        if (cancelled) return;
        console.error("Failed to load project files:", error);
        setIsIndexing(false);
      } finally {
        if (!cancelled) {
          setIsLoadingFiles(false);
          setIsIndexing(false);
        }
      }
    };

    const cleanup = () => {
      cancelled = true;
    };

    void loadFiles();
    return cleanup;
  }, [getAllProjectFiles, isVisible, nativeRootPaths, workspaceKey]);

  return {
    files,
    hasLoadedFiles: loadedForRootRef.current === workspaceKey,
    isLoadingFiles,
    isIndexing,
    rootFolderPath,
  };
};
