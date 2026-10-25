import { normalizeRepositoryPath } from "../api/git-repository-path";
import type { GitFile } from "../types/git.types";

// Note: .agents/notes/implemented/bug-fix/2026-10-21-git-large-untracked-directories.md

/**
 * True for an entry that summarizes a wholly untracked directory.
 *
 * Core reports a directory with more files than its summary threshold as one
 * `dir/` entry instead of one entry per file (#1385).
 */
export function isUntrackedDirectorySummary(file: Pick<GitFile, "untrackedFileCount">): boolean {
  return file.untrackedFileCount !== undefined;
}

/** Files an entry stands for in change counts. */
export function gitFileCount(file: Pick<GitFile, "untrackedFileCount">): number {
  return file.untrackedFileCount ?? 1;
}

type CountedEntry = Pick<GitFile, "path" | "untrackedFileCount">;

/** True when `file` lies below the summary `directory` in the same projection. */
export function isBelowUntrackedDirectory(directory: CountedEntry, file: CountedEntry): boolean {
  return (
    isUntrackedDirectorySummary(directory) &&
    file.path !== directory.path &&
    file.path.startsWith(directory.path)
  );
}

/**
 * Drops entries listed below a summary that is in the same set.
 *
 * Acting on the summary already acts on them; acting again would fail once the
 * summary's files are gone, and counting them again would double the total.
 */
export function withoutListedUntrackedContents<T extends CountedEntry>(files: readonly T[]): T[] {
  const summaries = files.filter(isUntrackedDirectorySummary);
  if (summaries.length === 0) return [...files];
  return files.filter(
    (file) => !summaries.some((directory) => isBelowUntrackedDirectory(directory, file)),
  );
}

/** Changed files in `files`, counting each summary as the files it stands for. */
export function countGitChangedFiles(files: readonly CountedEntry[] | undefined): number {
  if (!files || files.length === 0) return 0;
  const seen = new Set<string>();
  let count = 0;
  for (const file of withoutListedUntrackedContents(files)) {
    if (seen.has(file.path)) continue;
    seen.add(file.path);
    count += gitFileCount(file);
  }
  return count;
}

/**
 * The summary that contains a repository-relative path, if any.
 *
 * Status lists a summarized directory once, so a file below it has no entry
 * of its own; lookups that ask "is this file untracked" consult this instead.
 */
export function findContainingUntrackedDirectory(
  files: readonly GitFile[],
  repoPath: string | undefined,
  relativePath: string,
): GitFile | undefined {
  const repository = repoPath ? normalizeRepositoryPath(repoPath) : undefined;
  return files.find((file) => {
    if (!isUntrackedDirectorySummary(file)) return false;
    if (
      repository &&
      file.repositoryPath &&
      normalizeRepositoryPath(file.repositoryPath) !== repository
    )
      return false;
    const directory = file.repositoryRelativePath ?? file.path;
    return relativePath !== directory && relativePath.startsWith(directory);
  });
}
