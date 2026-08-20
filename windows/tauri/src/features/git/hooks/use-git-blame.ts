import { useCallback, useEffect } from "react";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { isGitChangeRelevant, subscribeToGitChanges } from "../events/git-events";
import { getGitBlameCacheKey, useGitBlameStore } from "../stores/git-blame.store";
import type { GitBlameLine } from "../types/git.types";
import { findGitBlameLine } from "../utils/git-blame-lines";

export function useGitBlame(filePath: string | undefined) {
  const rootFolderPath = useFileSystemStore((state) => state.rootFolderPath);
  const loadBlameForFile = useGitBlameStore((state) => state.actions.loadBlameForFile);
  const clearBlameForFile = useGitBlameStore((state) => state.actions.clearBlameForFile);
  const blameRevision = useGitBlameStore((state) => state.revision);
  const cacheKey =
    filePath && rootFolderPath ? getGitBlameCacheKey(rootFolderPath, filePath) : null;
  const blameData = useGitBlameStore((state) =>
    cacheKey ? state.blameData.get(cacheKey) : undefined,
  );

  useEffect(() => {
    if (!filePath || !rootFolderPath) return;
    void loadBlameForFile(rootFolderPath, filePath);
  }, [blameRevision, filePath, loadBlameForFile, rootFolderPath]);

  useEffect(() => {
    if (!filePath) return;

    const unsubscribe = subscribeToGitChanges((change) => {
      if (!isGitChangeRelevant(change, rootFolderPath, filePath)) return;
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

  return { getBlameForLine };
}
