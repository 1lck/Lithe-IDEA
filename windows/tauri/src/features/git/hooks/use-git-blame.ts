import { useCallback, useEffect } from "react";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { isGitChangeRelevant, subscribeToGitChanges } from "../events/git-events";
import { getGitBlameCacheKey, useGitBlameStore } from "../stores/git-blame.store";
import type { GitBlame, GitBlameLine } from "../types/git.types";
import { findGitBlameLine } from "../utils/git-blame-lines";

export function useGitBlame(filePath: string | undefined) {
  const rootFolderPath = useFileSystemStore((state) => state.rootFolderPath);
  const loadBlameForFile = useGitBlameStore((state) => state.actions.loadBlameForFile);
  const clearBlameForFile = useGitBlameStore((state) => state.actions.clearBlameForFile);
  const toggleBlameForFile = useGitBlameStore((state) => state.actions.toggleBlameForFile);
  const blameRevision = useGitBlameStore((state) => state.revision);
  const cacheKey =
    filePath && rootFolderPath ? getGitBlameCacheKey(rootFolderPath, filePath) : null;
  const blameData = useGitBlameStore((state) =>
    cacheKey ? state.blameData.get(cacheKey) : undefined,
  );
  // Annotate is a per-file action: the data is only worth reading while the
  // annotation is on, so a file never pays for blame it will not display.
  const blameVisible = useGitBlameStore((state) =>
    filePath ? state.visibleFiles.has(filePath) : false,
  );
  const repoPath = useGitBlameStore((state) =>
    filePath ? (state.fileToRepo.get(filePath) ?? null) : null,
  );

  useEffect(() => {
    if (!filePath || !rootFolderPath || !blameVisible) return;
    void loadBlameForFile(rootFolderPath, filePath);
  }, [blameRevision, blameVisible, filePath, loadBlameForFile, rootFolderPath]);

  useEffect(() => {
    if (!filePath) return;

    const unsubscribe = subscribeToGitChanges((change) => {
      if (!isGitChangeRelevant(change, rootFolderPath, filePath)) return;
      // Reloading keeps the annotation on: a commit must refresh the labels
      // rather than silently close annotate for the file.
      clearBlameForFile(filePath);
    });

    return unsubscribe;
  }, [clearBlameForFile, filePath, rootFolderPath]);

  const getBlameForLine = useCallback(
    (lineNumber: number): GitBlameLine | null => {
      if (!filePath || !blameData) return null;
      return findGitBlameLine(blameData.lines, lineNumber + 1);
    },
    [filePath, blameData],
  );

  const setBlameVisible = useCallback(
    (visible: boolean) => {
      if (filePath) toggleBlameForFile(filePath, visible);
    },
    [filePath, toggleBlameForFile],
  );

  return {
    blame: blameData,
    blameVisible,
    repoPath,
    getBlameForLine,
    setBlameVisible,
  };
}
