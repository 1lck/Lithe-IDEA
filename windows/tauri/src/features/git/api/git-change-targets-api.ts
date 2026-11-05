import { invoke as tauriInvoke } from "@/platform/tauri-core";
import type { GitFile } from "../types/git.types";
import { isUntrackedDirectorySummary } from "../utils/git-untracked-directories";
import {
  getGitFileRepositoryPath,
  getGitFileRepositoryRelativePath,
} from "../utils/git-status-selection";
import { normalizeRepositoryPath } from "./git-repository-path";

// Note: .agents/notes/implemented/bug-fix/2026-10-21-git-large-untracked-directories.md

/**
 * The selected rows one Git operation acts on (`git.normalizeChangeTargets`).
 *
 * Core drops rows listed below a selected untracked directory summary of the
 * same repository: acting on the summary already acts on them, and acting
 * again fails once the summary's files are gone. Rows keep their order.
 */
export async function normalizeGitChangeTargets<T extends GitFile>(
  files: readonly T[],
  fallbackRepoPath?: string,
): Promise<T[]> {
  if (files.length === 0) return [];
  const targets = files.map((file) => {
    const root = getGitFileRepositoryPath(file, fallbackRepoPath);
    if (!root) throw new Error("Missing Git repository path for change target");
    return {
      root: normalizeRepositoryPath(root),
      path: getGitFileRepositoryRelativePath(file),
      ...(isUntrackedDirectorySummary(file) ? { untrackedDirectory: true } : {}),
    };
  });
  const result = await tauriInvoke<{ indices: number[] }>("git.normalizeChangeTargets", {
    targets,
  });
  return result.indices.map((index) => {
    const file = files[index];
    if (!file) throw new Error("Invalid Git change target plan");
    return file;
  });
}

/**
 * What a Delete acts on: the normalized targets that still exist, and their
 * paths once each in path order.
 */
export async function resolveGitStatusDeletion<T extends GitFile>(
  entries: ReadonlyArray<{ files: ReadonlyArray<T> }>,
  fallbackRepoPath?: string,
): Promise<{ paths: string[]; targets: T[] }> {
  const targets = (
    await normalizeGitChangeTargets(
      entries.flatMap((entry) => entry.files),
      fallbackRepoPath,
    )
  ).filter((file) => file.status !== "deleted");
  const paths = [...new Set(targets.map((file) => file.path))].sort((left, right) =>
    left.localeCompare(right),
  );
  return { paths, targets };
}
