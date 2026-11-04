import type { GitFile } from "../types/git.types";
import type { WorkspaceCommitPathScope } from "../types/git-workspace-commit.types";
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
  /** Transient Core projection; never persisted. */
  projection?: { members: Map<string, string>; scope: WorkspaceCommitPathScope };
}
export const EMPTY_CHANGELISTS: LocalChangelists = {
  lists: [{ id: DEFAULT_CHANGELIST, name: "" }],
  activeId: DEFAULT_CHANGELIST,
  assignments: {},
};
export const changelistPathKey = (root: string, path: string) => JSON.stringify([root, path]);

/** Identity for matching a Core membership result to a rendered row. */
export function changelistFileKey(file: GitFile, fallback?: string): string | undefined {
  const root = getGitFileRepositoryPath(file, fallback);
  if (!root) return undefined;
  return JSON.stringify([
    root,
    getGitFileRepositoryRelativePath(file),
    getGitFileOriginalRepositoryRelativePath(file) ?? null,
    file.rawStatus?.includes("C") ?? false,
  ]);
}

/** Membership is supplied by the Core projection; missing rows fail closed. */
export function fileChangelist(state: LocalChangelists, file: GitFile, fallback?: string): string {
  const key = changelistFileKey(file, fallback);
  if (key && state.projection) return state.projection.members.get(key) ?? "";
  return Object.keys(state.assignments).length === 0 ? DEFAULT_CHANGELIST : "";
}

/** Validate only the storage wire shape; Core validates list semantics. */
export function isLocalChangelists(value: unknown): value is LocalChangelists {
  if (!value || typeof value !== "object") return false;
  const state = value as LocalChangelists;
  if (
    !Array.isArray(state.lists) ||
    typeof state.activeId !== "string" ||
    !state.assignments ||
    typeof state.assignments !== "object" ||
    Array.isArray(state.assignments)
  )
    return false;
  if (
    !state.lists.every(
      (list) => list && typeof list.id === "string" && typeof list.name === "string",
    )
  )
    return false;
  return Object.entries(state.assignments).every(([key, id]) => {
    try {
      const pair: unknown = JSON.parse(key);
      return (
        typeof id === "string" &&
        Array.isArray(pair) &&
        pair.length === 2 &&
        pair.every((part) => typeof part === "string")
      );
    } catch {
      return false;
    }
  });
}
