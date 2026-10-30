import { useCallback, useEffect } from "react";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { type GitChange, isGitChangeRelevant, subscribeToGitChanges } from "../events/git-events";
import { getGitBlameCacheKey, useGitBlameStore } from "../stores/git-blame.store";
import type { GitBlameLine } from "../types/git.types";
import { findGitBlameLine } from "../utils/git-blame-lines";

/**
 * Whether `change` can alter the blame of `filePath`: a write to the file
 * itself, or a repository change that may move its history. Index-only writes
 * (`working-tree`) leave both the commits and the file untouched; reacting to
 * them reran `git blame` for every open editor whenever the index was
 * rewritten, which is constant while a project imports.
 */
export function changeAffectsBlame(
  change: GitChange,
  repoPath: string | null | undefined,
  filePath: string,
): boolean {
  if (!isGitChangeRelevant(change, repoPath, filePath)) return false;
  if (change.filePath) return true;
  return !change.scopes || change.scopes.includes("history");
}

export function useGitBlame(filePath: string | undefined) {
  const rootFolderPath = useFileSystemStore((state) => state.rootFolderPath);
  const loadBlameForFile = useGitBlameStore((state) => state.actions.loadBlameForFile);
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
    if (!filePath || !rootFolderPath) return;

    const unsubscribe = subscribeToGitChanges((change) => {
      if (!changeAffectsBlame(change, rootFolderPath, filePath)) return;
      // Keep the shown annotation until the new blame replaces it.
      void loadBlameForFile(rootFolderPath, filePath, { refresh: true });
    });

    return unsubscribe;
  }, [filePath, loadBlameForFile, rootFolderPath]);

  const getBlameForLine = useCallback(
    (lineNumber: number): GitBlameLine | null => {
      if (!filePath || !blameData) return null;
      return findGitBlameLine(blameData.lines, lineNumber + 1);
    },
    [filePath, blameData],
  );

  return { getBlameForLine };
}
