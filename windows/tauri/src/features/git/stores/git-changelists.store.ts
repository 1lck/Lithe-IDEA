import { create } from "zustand";
import { persist, type PersistStorage } from "zustand/middleware";
import { createSafeJSONStorage } from "@/utils/zustand-storage";
import type { GitFile } from "../types/git.types";
import {
  assignChangelist,
  fileChangelist,
  DEFAULT_CHANGELIST,
  EMPTY_CHANGELISTS,
  isLocalChangelists,
  type LocalChangelists,
} from "../utils/git-changelists";

interface Persisted {
  workspaces: Record<string, LocalChangelists>;
}
interface ChangelistStore extends Persisted {
  unavailable: boolean;
  createList: (workspace: string, name: string, id: string) => boolean;
  renameList: (workspace: string, id: string, name: string) => boolean;
  removeList: (workspace: string, id: string) => void;
  activateList: (workspace: string, id: string) => void;
  rememberRenames: (workspace: string, files: readonly GitFile[], fallback?: string) => void;
  moveFiles: (workspace: string, files: readonly GitFile[], id: string, fallback?: string) => void;
}
const keyFor = (workspace: string) => JSON.stringify(workspace);
export const workspaceChangelists = (state: Persisted, workspace: string) =>
  state.workspaces[keyFor(workspace)] ?? EMPTY_CHANGELISTS;

export function createGitChangelistsStore(
  storage: PersistStorage<Persisted> = createSafeJSONStorage<Persisted>(),
) {
  let storageFailed = false;
  const guardedStorage: PersistStorage<Persisted> = {
    ...storage,
    setItem: (name, value) => {
      if (storageFailed) return;
      return storage.setItem(name, value);
    },
  };
  const store = create<ChangelistStore>()(
    persist(
      (set, get) => {
        const update = (
          workspace: string,
          action: (state: LocalChangelists) => LocalChangelists,
        ) => {
          if (!workspace || get().unavailable) return;
          try {
            set((state) => ({
              workspaces: {
                ...state.workspaces,
                [keyFor(workspace)]: action(workspaceChangelists(state, workspace)),
              },
            }));
          } catch {
            // Stop further writes and submissions; never silently discard a failed save.
            storageFailed = true;
            set({ unavailable: true });
          }
        };
        const validName = (state: LocalChangelists, name: string, except?: string) =>
          name.length > 0 &&
          name.length <= 100 &&
          !state.lists.some(
            (list) =>
              list.id !== except && list.name.toLocaleLowerCase() === name.toLocaleLowerCase(),
          );
        return {
          workspaces: {},
          unavailable: false,
          createList: (workspace, rawName, id) => {
            const name = rawName.trim();
            const state = workspaceChangelists(get(), workspace);
            if (
              get().unavailable ||
              !workspace ||
              !id ||
              state.lists.some((list) => list.id === id) ||
              !validName(state, name)
            )
              return false;
            update(workspace, (current) => ({
              ...current,
              lists: [...current.lists, { id, name }],
            }));
            return !get().unavailable;
          },
          renameList: (workspace, id, rawName) => {
            const name = rawName.trim();
            const state = workspaceChangelists(get(), workspace);
            if (
              get().unavailable ||
              id === DEFAULT_CHANGELIST ||
              !state.lists.some((list) => list.id === id) ||
              !validName(state, name, id)
            )
              return false;
            update(workspace, (current) => ({
              ...current,
              lists: current.lists.map((list) => (list.id === id ? { ...list, name } : list)),
            }));
            return !get().unavailable;
          },
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
          activateList: (workspace, id) =>
            update(workspace, (state) =>
              state.lists.some((list) => list.id === id) ? { ...state, activeId: id } : state,
            ),
          rememberRenames: (workspace, files, fallback) => {
            const current = workspaceChangelists(get(), workspace);
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
            if (JSON.stringify(next.assignments) !== JSON.stringify(current.assignments))
              update(workspace, () => next);
          },
          moveFiles: (workspace, files, id, fallback) =>
            update(workspace, (state) => assignChangelist(state, files, id, fallback)),
        };
      },
      {
        name: "git-local-changelists-v1",
        storage: guardedStorage,
        onRehydrateStorage: () => (_state, error) => {
          if (error) storageFailed = true;
        },
        partialize: ({ workspaces }) => ({ workspaces }),
        merge: (persisted, current) => {
          if (persisted === undefined) return current;
          const workspaces = (persisted as Persisted)?.workspaces;
          if (
            !workspaces ||
            typeof workspaces !== "object" ||
            Array.isArray(workspaces) ||
            !Object.values(workspaces).every(isLocalChangelists)
          ) {
            storageFailed = true;
            return { ...current, unavailable: true };
          }
          return { ...current, workspaces };
        },
      },
    ),
  );
  if (storageFailed) store.setState({ unavailable: true });
  return store;
}
export const useGitChangelistsStore = createGitChangelistsStore();
