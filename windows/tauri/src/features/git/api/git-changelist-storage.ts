import type { StateStorage } from "zustand/middleware";
import { isLocalChangelists, type LocalChangelists } from "../utils/git-changelists";

const STORAGE_VERSION = 0;
const LEGACY_STORAGE_KEY = "git-local-changelists-v1";
export const changelistStorageKey = (workspace: string) =>
  `git-local-changelists-workspace-v1:${JSON.stringify(workspace)}`;
export const isChangelistStorageEvent = (workspace: string, key: string | null) =>
  key === null || key === LEGACY_STORAGE_KEY || key === changelistStorageKey(workspace);

export interface ChangelistStorage {
  load: (workspace: string) => LocalChangelists | undefined;
  save: (workspace: string, state: LocalChangelists) => void;
}

/** Each write owns exactly one workspace key, never a window's cached workspace table. */
export function createChangelistStorage(
  getStorage: () => StateStorage = () => {
    if (!globalThis.localStorage) throw new Error("Changelist storage is unavailable");
    return globalThis.localStorage;
  },
): ChangelistStorage {
  const read = (key: string): unknown => {
    const raw = getStorage().getItem(key);
    if (raw === null) return undefined;
    // Production localStorage is synchronous. Never expose defaults during async hydration.
    if (typeof raw !== "string") throw new Error("Changelist storage must be synchronous");
    const value = JSON.parse(raw);
    if (!value || value.version !== STORAGE_VERSION || !value.state) {
      throw new Error("Unsupported changelist storage format");
    }
    return value.state;
  };
  return {
    load: (workspace) => {
      const current = read(changelistStorageKey(workspace));
      if (current !== undefined) {
        if (!isLocalChangelists(current)) throw new Error("Invalid changelist data");
        return current;
      }
      // Read old snapshots lazily. Keep the legacy key untouched as a migration backup;
      // once a workspace is saved, its independent key is authoritative.
      const legacy = read(LEGACY_STORAGE_KEY) as { workspaces?: unknown } | undefined;
      if (legacy === undefined) return undefined;
      const workspaces = legacy.workspaces;
      if (
        !workspaces ||
        typeof workspaces !== "object" ||
        Array.isArray(workspaces) ||
        !Object.values(workspaces).every(isLocalChangelists)
      ) {
        throw new Error("Invalid legacy changelist data");
      }
      return (workspaces as Record<string, LocalChangelists>)[JSON.stringify(workspace)];
    },
    save: (workspace, state) => {
      if (!isLocalChangelists(state)) throw new Error("Invalid changelist data");
      getStorage().setItem(changelistStorageKey(workspace), JSON.stringify({ version: STORAGE_VERSION, state }));
    },
  };
}
