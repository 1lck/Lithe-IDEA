import { invoke } from "@/platform/tauri-core";
import type { GitFile } from "../types/git.types";
import type {
  WorkspaceCommitPathScope,
  WorkspaceRepositoryBinding,
} from "../types/git-workspace-commit.types";
import { changelistPathKey, type LocalChangelists } from "../utils/git-changelists";
import {
  getGitFileOriginalRepositoryRelativePath,
  getGitFileRepositoryPath,
  getGitFileRepositoryRelativePath,
} from "../utils/git-status-selection";

interface WireFile {
  root: string;
  path: string;
  originalPath?: string;
  isCopy: boolean;
}
interface WireState {
  lists: LocalChangelists["lists"];
  activeId: string;
  assignments: Record<string, Record<string, string>>;
}
interface WireProjection {
  state: WireState;
  members: string[];
  scope: WorkspaceCommitPathScope;
}
export type ChangelistAction =
  | { type: "rememberRenames" }
  | { type: "move"; id: string; files: GitFile[] }
  | { type: "remove" | "activate"; id: string }
  | { type: "create" | "rename"; id: string; name: string };

export interface ChangelistProjection {
  state: LocalChangelists;
  members: string[];
  scope: WorkspaceCommitPathScope;
}

/** Converts host path identities to Core's wire format without reimplementing membership. */
export async function projectChangelists(
  state: LocalChangelists,
  files: readonly GitFile[],
  repositories: WorkspaceRepositoryBinding[],
  fallback?: string,
  action?: ChangelistAction,
): Promise<ChangelistProjection> {
  const assignments: Record<string, Record<string, string>> = Object.create(null);
  for (const [key, id] of Object.entries(state.assignments)) {
    const [root, path] = JSON.parse(key) as [string, string];
    (assignments[root] ??= Object.create(null))[path] = id;
  }
  const file = (item: GitFile): WireFile => {
    const root = getGitFileRepositoryPath(item, fallback);
    if (!root) throw new Error("Missing ChangeList repository root");
    return {
      root,
      path: getGitFileRepositoryRelativePath(item),
      originalPath: getGitFileOriginalRepositoryRelativePath(item),
      isCopy: item.rawStatus?.includes("C") ?? false,
    };
  };
  const wireAction =
    action?.type === "move" ? { ...action, files: action.files.map(file) } : action;
  const response = await invoke<WireProjection>("git.changelists", {
    state: { lists: state.lists, activeId: state.activeId, assignments },
    files: files.map(file),
    repositories,
    action: wireAction,
  });
  const validIds = new Set(response.state.lists.map((list) => list.id));
  if (
    response.members.length !== files.length ||
    response.members.some((id) => !validIds.has(id))
  ) {
    throw new Error("Invalid ChangeList projection");
  }
  const localAssignments: Record<string, string> = Object.create(null);
  for (const [root, paths] of Object.entries(response.state.assignments)) {
    for (const [path, id] of Object.entries(paths))
      localAssignments[changelistPathKey(root, path)] = id;
  }
  return {
    state: {
      lists: response.state.lists,
      activeId: response.state.activeId,
      assignments: localAssignments,
    },
    members: response.members,
    scope: response.scope,
  };
}
