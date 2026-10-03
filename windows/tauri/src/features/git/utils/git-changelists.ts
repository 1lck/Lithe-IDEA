import type { GitFile } from "../types/git.types";
import type {
  WorkspaceCommitPathScope,
  WorkspaceRepositoryBinding,
} from "../types/git-workspace-commit.types";
import {
  getGitFileOriginalRepositoryRelativePath,
  getGitFileRepositoryPath,
  getGitFileRepositoryRelativePath,
} from "./git-status-selection";

export const DEFAULT_CHANGELIST = "default";
export interface LocalChangelist {
  id: string;
  name: string;
}
export interface LocalChangelists {
  lists: LocalChangelist[];
  activeId: string;
  /** JSON tuples of repository root and literal relative path; retained while files are clean. */
  assignments: Record<string, string>;
}
export const EMPTY_CHANGELISTS: LocalChangelists = {
  lists: [{ id: DEFAULT_CHANGELIST, name: "" }],
  activeId: DEFAULT_CHANGELIST,
  assignments: {},
};
export const changelistPathKey = (root: string, path: string) => JSON.stringify([root, path]);

export function fileChangelist(state: LocalChangelists, file: GitFile, fallback?: string): string {
  const root = getGitFileRepositoryPath(file, fallback);
  if (!root) return DEFAULT_CHANGELIST;
  const current =
    state.assignments[changelistPathKey(root, getGitFileRepositoryRelativePath(file))];
  const original = getGitFileOriginalRepositoryRelativePath(file);
  return (
    current ??
    (original ? state.assignments[changelistPathKey(root, original)] : undefined) ??
    DEFAULT_CHANGELIST
  );
}

/** Carry both sides of a reported rename; moving lists never stages or unstages a file. */
export function assignChangelist(
  state: LocalChangelists,
  files: readonly GitFile[],
  list: string,
  fallback?: string,
): LocalChangelists {
  if (!state.lists.some(({ id }) => id === list)) return state;
  const assignments = { ...state.assignments };
  for (const file of files) {
    const root = getGitFileRepositoryPath(file, fallback);
    if (!root) continue;
    for (const path of [
      getGitFileRepositoryRelativePath(file),
      getGitFileOriginalRepositoryRelativePath(file),
    ]) {
      if (path) assignments[changelistPathKey(root, path)] = list;
    }
  }
  return { ...state, assignments };
}

/** Snapshot the active list for Core, including files absent from the last status refresh. */
export function changelistCommitScope(
  state: LocalChangelists,
  repositories: WorkspaceRepositoryBinding[],
  files: readonly GitFile[],
  fallback?: string,
): WorkspaceCommitPathScope {
  let snapshot = state;
  // Git reports renames; do not infer them from names or filesystem scans.
  for (const file of files) {
    if (getGitFileOriginalRepositoryRelativePath(file)) {
      snapshot = assignChangelist(
        snapshot,
        [file],
        fileChangelist(state, file, fallback),
        fallback,
      );
    }
  }
  const include = state.activeId !== DEFAULT_CHANGELIST;
  const paths: Record<string, string[]> = Object.create(null);
  const ids = new Map(repositories.map(({ id, root }) => [root, id]));
  for (const [key, list] of Object.entries(snapshot.assignments)) {
    const [root, path] = JSON.parse(key) as [string, string];
    const id = ids.get(root);
    if (id === undefined || (include ? list !== state.activeId : list === DEFAULT_CHANGELIST))
      continue;
    (paths[id] ??= []).push(path);
  }
  for (const id of Object.keys(paths)) paths[id] = [...new Set(paths[id])].sort();
  return { include, paths };
}

/** Reject corrupt metadata rather than silently exposing protected files to bulk staging. */
export function isLocalChangelists(value: unknown): value is LocalChangelists {
  if (!value || typeof value !== "object") return false;
  const state = value as LocalChangelists;
  if (
    !Array.isArray(state.lists) ||
    !state.lists.length ||
    typeof state.activeId !== "string" ||
    !state.assignments ||
    typeof state.assignments !== "object" ||
    Array.isArray(state.assignments)
  )
    return false;
  const ids = new Set<string>();
  for (const list of state.lists) {
    if (
      !list ||
      typeof list.id !== "string" ||
      !list.id ||
      typeof list.name !== "string" ||
      (list.id !== DEFAULT_CHANGELIST && !list.name.trim()) ||
      ids.has(list.id)
    )
      return false;
    ids.add(list.id);
  }
  if (!ids.has(DEFAULT_CHANGELIST) || !ids.has(state.activeId)) return false;
  return Object.entries(state.assignments).every(([key, id]) => {
    try {
      const pair: unknown = JSON.parse(key);
      return (
        ids.has(id) &&
        Array.isArray(pair) &&
        pair.length === 2 &&
        pair.every((part) => typeof part === "string" && part.length > 0)
      );
    } catch {
      return false;
    }
  });
}
