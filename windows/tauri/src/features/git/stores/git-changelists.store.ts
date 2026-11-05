import { create } from "zustand";
import { frontendTrace } from "@/utils/frontend-trace";
import { createChangelistStorage, type ChangelistStorage } from "../api/git-changelist-storage";
import {
  projectChangelists,
  type ChangelistAction,
  type ChangelistProjection,
} from "../api/git-changelist-core";
import type { GitFile } from "../types/git.types";
import type { WorkspaceRepositoryBinding } from "../types/git-workspace-commit.types";
import { EMPTY_CHANGELISTS, type LocalChangelists } from "../utils/git-changelists";

interface ChangelistState {
  workspaces: Record<string, LocalChangelists>;
  pending: Record<string, number>;
  unavailable: boolean;
}
interface ChangelistStore extends ChangelistState {
  loadWorkspace: (workspace: string) => Promise<boolean>;
  projectCurrent: (
    workspace: string,
    files: readonly GitFile[],
    fallback?: string,
    repositories?: WorkspaceRepositoryBinding[],
  ) => Promise<ChangelistProjection | undefined>;
  createList: (workspace: string, name: string, id: string) => Promise<boolean>;
  renameList: (workspace: string, id: string, name: string) => Promise<boolean>;
  removeList: (workspace: string, id: string) => Promise<boolean>;
  activateList: (workspace: string, id: string) => Promise<boolean>;
  rememberRenames: (
    workspace: string,
    files: readonly GitFile[],
    fallback?: string,
  ) => Promise<boolean>;
  moveFiles: (
    workspace: string,
    files: readonly GitFile[],
    id: string,
    fallback?: string,
  ) => Promise<boolean>;
}
const keyFor = (workspace: string) => JSON.stringify(workspace);
export const workspaceChangelists = (state: ChangelistState, workspace: string) =>
  state.workspaces[keyFor(workspace)] ?? EMPTY_CHANGELISTS;
export const changelistsUnavailable = (state: ChangelistState, workspace: string) =>
  state.unavailable ||
  !state.workspaces[keyFor(workspace)] ||
  (state.pending[keyFor(workspace)] ?? 0) > 0;

type Lock = <T>(workspace: string, task: () => Promise<T>) => Promise<T>;
const crossWindowLock: Lock = async (workspace, task) => {
  if (!navigator.locks) throw new Error("ChangeList cross-window locking is unavailable");
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 30_000);
  try {
    return await navigator.locks.request(
      `lithe-git-changelists:${workspace}`,
      { signal: controller.signal },
      task,
    );
  } finally {
    clearTimeout(timeout);
  }
};

/** Read, reduce and save under one cross-window lock so an async Core call cannot overwrite newer metadata. */
export function createGitChangelistsStore(
  storage: ChangelistStorage = createChangelistStorage(),
  reduce = projectChangelists,
  lock: Lock = crossWindowLock,
) {
  return create<ChangelistStore>((set, get) => {
    const update = async (
      workspace: string,
      action?: ChangelistAction,
      files: readonly GitFile[] = [],
      fallback?: string,
    ) => {
      if (!workspace || get().unavailable) return false;
      const key = keyFor(workspace);
      set((state) => ({ pending: { ...state.pending, [key]: (state.pending[key] ?? 0) + 1 } }));
      try {
        return await lock(workspace, async () => {
          const current = storage.load(workspace) ?? EMPTY_CHANGELISTS;
          const result = await reduce(current, files, [], fallback, action);
          if (action && JSON.stringify(current) !== JSON.stringify(result.state))
            storage.save(workspace, result.state);
          set((state) => ({ workspaces: { ...state.workspaces, [key]: result.state } }));
          return true;
        });
      } catch (error) {
        if (!(error instanceof Error && error.message.includes("INVALID_CHANGELIST_ACTION"))) {
          frontendTrace("warn", "git.changelists", "ChangeList storage or reducer unavailable");
          set({ unavailable: true });
        }
        return false;
      } finally {
        set((state) => ({
          pending: { ...state.pending, [key]: Math.max((state.pending[key] ?? 1) - 1, 0) },
        }));
      }
    };
    const projectCurrent = async (
      workspace: string,
      files: readonly GitFile[],
      fallback?: string,
      repositories: WorkspaceRepositoryBinding[] = [],
    ): Promise<ChangelistProjection | undefined> => {
      if (!workspace || get().unavailable) return undefined;
      const key = keyFor(workspace);
      set((state) => ({ pending: { ...state.pending, [key]: (state.pending[key] ?? 0) + 1 } }));
      try {
        return await lock(workspace, async () => {
          const current = storage.load(workspace) ?? EMPTY_CHANGELISTS;
          const result = await reduce(current, files, repositories, fallback);
          set((state) => ({ workspaces: { ...state.workspaces, [key]: result.state } }));
          return result;
        });
      } catch {
        frontendTrace("warn", "git.changelists", "ChangeList validation unavailable");
        set({ unavailable: true });
        return undefined;
      } finally {
        set((state) => ({
          pending: { ...state.pending, [key]: Math.max((state.pending[key] ?? 1) - 1, 0) },
        }));
      }
    };
    return {
      workspaces: {},
      pending: {},
      unavailable: false,
      loadWorkspace: (workspace) => update(workspace),
      projectCurrent,
      createList: (workspace, name, id) => update(workspace, { type: "create", id, name }),
      renameList: (workspace, id, name) => update(workspace, { type: "rename", id, name }),
      removeList: (workspace, id) => update(workspace, { type: "remove", id }),
      activateList: (workspace, id) => update(workspace, { type: "activate", id }),
      rememberRenames: (workspace, files, fallback) =>
        update(workspace, { type: "rememberRenames" }, files, fallback),
      moveFiles: (workspace, files, id, fallback) =>
        update(workspace, { type: "move", id, files: [...files] }, [], fallback),
    };
  });
}
export const useGitChangelistsStore = createGitChangelistsStore();
