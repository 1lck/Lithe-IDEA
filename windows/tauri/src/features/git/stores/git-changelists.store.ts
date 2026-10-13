import { create } from "zustand";
import { createChangelistStorage, type ChangelistStorage } from "../api/git-changelist-storage";
import type { GitFile } from "../types/git.types";
import {
  assignChangelist,
  fileChangelist,
  DEFAULT_CHANGELIST,
  EMPTY_CHANGELISTS,
  type LocalChangelists,
} from "../utils/git-changelists";

interface ChangelistState {
  workspaces: Record<string, LocalChangelists>;
  unavailable: boolean;
}
interface ChangelistStore extends ChangelistState {
  loadWorkspace: (workspace: string) => void;
  createList: (workspace: string, name: string, id: string) => boolean;
  renameList: (workspace: string, id: string, name: string) => boolean;
  removeList: (workspace: string, id: string) => void;
  activateList: (workspace: string, id: string) => void;
  rememberRenames: (workspace: string, files: readonly GitFile[], fallback?: string) => void;
  moveFiles: (workspace: string, files: readonly GitFile[], id: string, fallback?: string) => void;
}
const keyFor = (workspace: string) => JSON.stringify(workspace);
export const workspaceChangelists = (state: ChangelistState, workspace: string) =>
  state.workspaces[keyFor(workspace)] ?? EMPTY_CHANGELISTS;
export const changelistsUnavailable = (state: ChangelistState, workspace: string) =>
  state.unavailable || !state.workspaces[keyFor(workspace)];

export function createGitChangelistsStore(storage: ChangelistStorage = createChangelistStorage()) {
  return create<ChangelistStore>((set, get) => {
    const publish = (workspace: string, value: LocalChangelists) =>
      set((state) => ({ workspaces: { ...state.workspaces, [keyFor(workspace)]: value } }));
    const update = (
      workspace: string,
      action: (state: LocalChangelists) => LocalChangelists | undefined,
    ) => {
      if (!workspace || get().unavailable) return false;
      try {
        // Read the target workspace at the action boundary; another window may have
        // changed it since hydration. Different workspaces never share write keys.
        const current = storage.load(workspace) ?? EMPTY_CHANGELISTS;
        const next = action(current);
        if (next && next !== current) storage.save(workspace, next);
        publish(workspace, next ?? current);
        return next !== undefined;
      } catch {
        set({ unavailable: true });
        return false;
      }
    };
    const validName = (state: LocalChangelists, name: string, except?: string) =>
      name.length > 0 &&
      name.length <= 100 &&
      !state.lists.some(
        (list) => list.id !== except && list.name.toLocaleLowerCase() === name.toLocaleLowerCase(),
      );
    return {
      workspaces: {},
      unavailable: false,
      loadWorkspace: (workspace) => {
        update(workspace, (current) => current);
      },
      createList: (workspace, rawName, id) =>
        update(workspace, (state) => {
          const name = rawName.trim();
          if (!id || state.lists.some((list) => list.id === id) || !validName(state, name))
            return undefined;
          return { ...state, lists: [...state.lists, { id, name }] };
        }),
      renameList: (workspace, id, rawName) =>
        update(workspace, (state) => {
          const name = rawName.trim();
          if (
            id === DEFAULT_CHANGELIST ||
            !state.lists.some((list) => list.id === id) ||
            !validName(state, name, id)
          )
            return undefined;
          return {
            ...state,
            lists: state.lists.map((list) => (list.id === id ? { ...list, name } : list)),
          };
        }),
      removeList: (workspace, id) => {
        if (id === DEFAULT_CHANGELIST) return;
        update(workspace, (state) => ({
          lists: state.lists.filter((list) => list.id !== id),
          activeId: state.activeId === id ? DEFAULT_CHANGELIST : state.activeId,
          assignments: Object.fromEntries(
            Object.entries(state.assignments).map(([path, list]) => [
              path,
              list === id ? DEFAULT_CHANGELIST : list,
            ]),
          ),
        }));
      },
      activateList: (workspace, id) => {
        update(workspace, (state) =>
          state.lists.some((list) => list.id === id) ? { ...state, activeId: id } : undefined,
        );
      },
      rememberRenames: (workspace, files, fallback) => {
        update(workspace, (current) => {
          let next = current;
          for (const file of files) {
            if (file.repositoryOriginalRelativePath ?? file.originalPath) {
              next = assignChangelist(
                next,
                [file],
                fileChangelist(current, file, fallback),
                fallback,
              );
            }
          }
          return JSON.stringify(next.assignments) === JSON.stringify(current.assignments)
            ? current
            : next;
        });
      },
      moveFiles: (workspace, files, id, fallback) => {
        update(workspace, (state) => assignChangelist(state, files, id, fallback));
      },
    };
  });
}
export const useGitChangelistsStore = createGitChangelistsStore();
