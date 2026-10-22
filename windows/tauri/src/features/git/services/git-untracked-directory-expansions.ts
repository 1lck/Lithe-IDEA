import { normalizeRepositoryPath } from "../api/git-repository-path";
import type { GitFile } from "../types/git.types";
import { isUntrackedDirectorySummary } from "../utils/git-untracked-directories";

/**
 * Untracked directory summaries the Commit view shows expanded, keyed by
 * repository and then by repository-relative `dir/` path.
 *
 * Expanded contents are listed again on every status read and merged into the
 * repository snapshot right after their summary, so `repositoryStatuses` stays
 * the only published status and every consumer sees the same rows. Keys are
 * repositories, so workspaces sharing a repository share its expansions; the
 * state is never persisted and an expansion ends when its summary disappears.
 */
const expandedDirectories = new Map<string, Set<string>>();

export function isUntrackedDirectoryExpanded(repoPath: string, directory: string): boolean {
  return expandedDirectories.get(normalizeRepositoryPath(repoPath))?.has(directory) ?? false;
}

/** Expands or collapses a summary; collapsing also forgets summaries listed below it. */
export function setUntrackedDirectoryExpanded(
  repoPath: string,
  directory: string,
  expanded: boolean,
): void {
  const key = normalizeRepositoryPath(repoPath);
  const directories = expandedDirectories.get(key) ?? new Set<string>();
  if (expanded) {
    directories.add(directory);
  } else {
    for (const candidate of [...directories]) {
      if (candidate.startsWith(directory)) directories.delete(candidate);
    }
  }
  if (directories.size > 0) expandedDirectories.set(key, directories);
  else expandedDirectories.delete(key);
}

/**
 * Inserts the listed contents of every expanded summary still in `files`
 * directly after it. Nested expanded summaries are listed in the same pass.
 *
 * Expansions whose summary is no longer reported (the directory was staged,
 * deleted, or now holds tracked files) are forgotten. A listing that fails
 * keeps its expansion so the next read retries, and leaves the summary
 * collapsed rather than publishing a partial directory.
 */
export async function listExpandedUntrackedDirectories(
  repoPath: string,
  files: readonly GitFile[],
  list: (directory: string) => Promise<GitFile[] | null>,
): Promise<GitFile[]> {
  const key = normalizeRepositoryPath(repoPath);
  const requested = expandedDirectories.get(key);
  if (!requested || requested.size === 0) return [...files];
  const requestedDirectories = new Set(requested);
  const result = [...files];
  for (let index = 0; index < result.length; index += 1) {
    const file = result[index]!;
    if (!isUntrackedDirectorySummary(file) || !requestedDirectories.has(file.path)) continue;
    const contents = await list(file.path);
    if (contents) result.splice(index + 1, 0, ...contents);
  }
  const present = new Set(result.filter(isUntrackedDirectorySummary).map((file) => file.path));
  // Keep expansions toggled while the listing ran; forget only those this read could check.
  const current = expandedDirectories.get(key);
  if (current) {
    for (const directory of requestedDirectories) {
      if (!present.has(directory)) current.delete(directory);
    }
    if (current.size === 0) expandedDirectories.delete(key);
  }
  return result;
}
