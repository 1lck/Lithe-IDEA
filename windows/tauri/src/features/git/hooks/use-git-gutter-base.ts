import { useEffect, useRef, useState } from "react";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { getFullContextFileDiff } from "../api/git-diff-api";
import { resolveRepositoryForFile } from "../api/git-repo-api";
import { isGitChangeRelevant, subscribeToGitChanges } from "../events/git-events";
import { useGitStore } from "../stores/git.store";
import {
  gitGutterBaseFromDiff,
  splitGitGutterLines,
  type GitGutterBaseSource,
} from "../utils/git-gutter-changes";

/** The Git index version of one editor file, which gutter markers compare against. */
export interface GitGutterBase {
  repoPath: string;
  /** Repository-relative path with `/` separators, as hunk patches require. */
  filePath: string;
  lines: string[];
}

/**
 * Resolves the comparison base for a file. A null result means the file has
 * no markers: it is untracked, outside a repository, binary, or the read failed.
 */
export async function loadGitGutterBase(
  rootPath: string,
  filePath: string,
  savedContent: () => string,
): Promise<GitGutterBase | null> {
  const resolved = await resolveRepositoryForFile(rootPath, filePath);
  if (!resolved) return null;
  const status = useGitStore.getState().workspaceGitStatus;
  const untracked = status?.files.some(
    (file) =>
      file.status === "untracked" &&
      (file.repositoryRelativePath ?? file.path) === resolved.filePath,
  );
  if (untracked) return null;

  const source: GitGutterBaseSource | null = gitGutterBaseFromDiff(
    await getFullContextFileDiff(resolved.repoPath, resolved.filePath, false),
  );
  if (!source) return null;
  return {
    ...resolved,
    // No index-to-worktree difference: the saved file is the index version.
    lines: source.kind === "lines" ? source.lines : splitGitGutterLines(savedContent()),
  };
}

/**
 * Loads the gutter base for the active editor and reloads it on Git changes
 * (save, stage, external edits). Results for a previous file or an older
 * request never replace the current one.
 */
export function useGitGutterBase(
  filePath: string | undefined,
  savedContent: () => string,
  savedRevision: unknown,
): GitGutterBase | null {
  const rootFolderPath = useFileSystemStore((state) => state.rootFolderPath);
  const [state, setState] = useState<{ key: string; base: GitGutterBase | null } | null>(null);
  const [refresh, setRefresh] = useState(0);
  const key = filePath && rootFolderPath ? JSON.stringify([rootFolderPath, filePath]) : null;
  // Read at request time; `savedRevision` is the dependency that says it changed.
  const savedContentRef = useRef(savedContent);
  savedContentRef.current = savedContent;

  useEffect(() => {
    if (!filePath || !rootFolderPath) return;
    return subscribeToGitChanges((change) => {
      if (isGitChangeRelevant(change, rootFolderPath, filePath)) setRefresh((value) => value + 1);
    });
  }, [filePath, rootFolderPath]);

  useEffect(() => {
    if (!key || !filePath || !rootFolderPath) return;
    let cancelled = false;
    void loadGitGutterBase(rootFolderPath, filePath, () => savedContentRef.current())
      .catch((error) => {
        console.error("Failed to load Git gutter base:", error);
        return null;
      })
      .then((base) => {
        if (!cancelled) setState({ key, base });
      });
    return () => {
      cancelled = true;
    };
  }, [key, filePath, rootFolderPath, refresh, savedRevision]);

  return state && state.key === key ? state.base : null;
}
