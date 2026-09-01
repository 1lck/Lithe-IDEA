import type { GitFile } from "../types/git.types";

export function resolveGitFileMutationPaths(files: readonly GitFile[]): string[] {
  return [
    ...new Set(files.flatMap((file) => [file.originalPath, file.path].filter(Boolean) as string[])),
  ].sort((left, right) => left.localeCompare(right));
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

export function resolveGitStatusDeletionPaths(
  entries: ReadonlyArray<{
    files: ReadonlyArray<{ path: string; status: string }>;
  }>,
): string[] {
  return [
    ...new Set(
      entries.flatMap((entry) =>
        entry.files.filter((file) => file.status !== "deleted").map((file) => file.path),
      ),
    ),
  ].sort((left, right) => left.localeCompare(right));
}
