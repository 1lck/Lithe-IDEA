import { normalizeRepositoryPath } from "../api/git-repository-path";
import type { GitFile } from "../types/git.types";

export function getGitFileRepositoryPath(file: GitFile, fallbackRepoPath?: string): string | null {
  return file.repositoryPath ?? fallbackRepoPath ?? null;
}

export function getGitFileRepositoryRelativePath(file: GitFile): string {
  return file.repositoryRelativePath ?? file.path;
}

export function getGitFileOriginalRepositoryRelativePath(file: GitFile): string | undefined {
  return file.repositoryOriginalRelativePath ?? file.originalPath;
}

export function resolveGitFileMutationPaths(files: readonly GitFile[]): string[] {
  return [
    ...new Set(
      files.flatMap(
        (file) =>
          [
            getGitFileOriginalRepositoryRelativePath(file),
            getGitFileRepositoryRelativePath(file),
          ].filter(Boolean) as string[],
      ),
    ),
  ].sort((left, right) => left.localeCompare(right));
}

export function resolveGitFilesForStagedState(
  files: readonly GitFile[],
  staged: boolean,
): GitFile[] {
  const resolvedFiles = new Map<string, GitFile>();

  for (const file of files) {
    if (file.staged === staged && !(staged && file.worktree)) continue;
    const repositoryPath = getGitFileRepositoryPath(file) ?? "";
    const filePath = getGitFileRepositoryRelativePath(file);
    resolvedFiles.set(`${repositoryPath}\0${filePath}`, file);
  }

  return [...resolvedFiles.values()];
}

export function updateGitStatusSelection(
  selectedEntryIds: ReadonlySet<string>,
  entryId: string,
  additive: boolean,
): Set<string> {
  if (!additive) return new Set([entryId]);

  const next = new Set(selectedEntryIds);
  if (next.has(entryId)) {
    next.delete(entryId);
  } else {
    next.add(entryId);
  }
  return next;
}

export function resolveGitStatusContextSelection(
  selectedEntryIds: ReadonlySet<string>,
  entryId: string,
): Set<string> {
  return selectedEntryIds.has(entryId) ? new Set(selectedEntryIds) : new Set([entryId]);
}

export function collapseNestedGitStatusPaths(paths: string[]): string[] {
  const normalizedPaths = [...new Set(paths.map((path) => path.replace(/\\/g, "/")))]
    .filter(Boolean)
    .sort((left, right) => left.length - right.length || left.localeCompare(right));
  const collapsedPaths: string[] = [];

  for (const path of normalizedPaths) {
    if (collapsedPaths.some((parent) => path === parent || path.startsWith(`${parent}/`))) {
      continue;
    }
    collapsedPaths.push(path);
  }

  return collapsedPaths.sort((left, right) => left.localeCompare(right));
}

export function buildGitIgnorePaths(
  entries: Array<{ kind: "file" | "folder"; path: string }>,
): string[] {
  const folderPaths = new Set(
    entries
      .filter((entry) => entry.kind === "folder")
      .map((entry) => entry.path.replace(/\\/g, "/").replace(/\/+$/, "")),
  );

  return collapseNestedGitStatusPaths(entries.map((entry) => entry.path)).map((path) =>
    folderPaths.has(path) ? `${path}/` : path,
  );
}

/** Check the refreshed presentation before moving focus to the commit editor. */
export function refreshedCommitSelectionMatches(
  selected: readonly GitFile[],
  current: readonly GitFile[],
  fallbackRepoPath?: string,
): boolean {
  const groups = new Map<string, Set<string>>();
  for (const file of selected) {
    const root = getGitFileRepositoryPath(file, fallbackRepoPath);
    if (!root) return false;
    const key = normalizeRepositoryPath(root);
    const paths = groups.get(key) ?? new Set<string>();
    paths.add(getGitFileRepositoryRelativePath(file));
    groups.set(key, paths);
  }
  const matched = new Map<string, Set<string>>();
  for (const file of current) {
    if (!file.staged) continue;
    const root = getGitFileRepositoryPath(file, fallbackRepoPath);
    if (!root) return false;
    const key = normalizeRepositoryPath(root);
    const paths = groups.get(key);
    if (!paths) return false;
    const path = getGitFileRepositoryRelativePath(file);
    let owner = paths.has(path) ? path : undefined;
    if (!owner) {
      for (let index = path.indexOf("/"); index >= 0; index = path.indexOf("/", index + 1)) {
        const directory = path.slice(0, index + 1);
        if (paths.has(directory)) {
          owner = directory;
          break;
        }
      }
    }
    if (!owner) return false;
    const found = matched.get(key) ?? new Set<string>();
    found.add(owner);
    matched.set(key, found);
  }
  return [...groups].every(([root, paths]) => matched.get(root)?.size === paths.size);
}
