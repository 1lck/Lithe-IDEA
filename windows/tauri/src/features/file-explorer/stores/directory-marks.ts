import {
  indexingEvent,
  subscribeToIndexingChanges,
  indexingSettingsStorageKey,
  readIndexingSettings,
  writeIndexingSettings,
  IndexingSettingsError,
  type IndexingErrorCode,
} from "./workspace-indexing";
import { directoryMarksStorageKey as key, readDirectoryMarks, type DirectoryAction, type DirectoryMark, type DirectoryMarks as Marks } from "./directory-marks-storage";
export { DIRECTORY_MARKS, readDirectoryMarks, type DirectoryAction, type DirectoryMark } from "./directory-marks-storage";
import { invoke } from "@/platform/tauri-core";
import { useCallback, useEffect, useState } from "react";
import { closestWorkspaceRoot } from "@/features/workspace/types/workspace-root";
import {
  getRelativePath,
  isCaseInsensitivePath,
  getPathIdentity,
  pathStartsWithRoot,
} from "@/utils/path-helpers";

const eventName = "lithe:directory-marks-changed";

const markPathIdentity = (root: string, relativePath: string): string => {
  const normalized = relativePath.replace(/\\/g, "/");
  return isCaseInsensitivePath(root) ? normalized.toLowerCase() : normalized;
};
function writeMarks(root: string, marks: Marks) {
  window.localStorage.setItem(key(root), JSON.stringify({ version: 1, marks }));
  window.dispatchEvent(new window.CustomEvent(eventName, { detail: root }));
}
/** The rule state of one workspace root, exactly as Rust Core's directory rules model it. */
interface DirectoryRules {
  marks: Marks;
  includedDirectories: string[];
  previousRoles: Record<string, string>;
}

const readRules = (root: string): DirectoryRules => {
  const settings = readIndexingSettings(root);
  return {
    marks: readDirectoryMarks(root),
    includedDirectories: settings.includedDirectories,
    previousRoles: settings.previousRoles,
  };
};

/** Stores Core's rule state in the two preference entries it is split across. */
const storeRules = (root: string, rules: DirectoryRules, settings = readIndexingSettings(root)): [string, string][] => [
  [key(root), JSON.stringify({ version: 1, marks: rules.marks })],
  [
    indexingSettingsStorageKey(root),
    JSON.stringify({ ...settings, includedDirectories: rules.includedDirectories, previousRoles: rules.previousRoles }),
  ],
];

const relativeTo = (root: string, path: string): string =>
  getRelativePath(path, root).replace(/\\/g, "/") || ".";

/**
 * Moves or drops the rules of a moved, renamed or deleted directory inside one root.
 * Core owns the migration (`workspace.relocateDirectoryRules`); this only loads and
 * persists the root's preferences.
 */
export async function migrateDirectoryMarks(root: string, source: string, destination?: string) {
  if (!pathStartsWithRoot(source, root)) return;
  const rules = readRules(root);
  const { rules: next } = await invoke<{ rules: DirectoryRules }>("workspace.relocateDirectoryRules", {
    source: relativeTo(root, source),
    destination: destination && pathStartsWithRoot(destination, root) ? relativeTo(root, destination) : undefined,
    caseInsensitive: isCaseInsensitivePath(root),
    rules,
  });
  if (JSON.stringify(next) === JSON.stringify(rules)) return;
  const settings = readIndexingSettings(root);
  writeIndexingSettings(root, { ...settings, includedDirectories: next.includedDirectories, previousRoles: next.previousRoles });
  if (JSON.stringify(next.marks) !== JSON.stringify(rules.marks)) writeMarks(root, next.marks);
}
/** The closest workspace owns preferences, including nested added roots. */
export function directoryMarkRoot(path: string, roots: readonly string[]): string | undefined {
  return closestWorkspaceRoot(path, roots);
}

export async function migrateWorkspaceDirectoryMarks(roots: readonly string[], source: string, destination?: string) {
  const root = directoryMarkRoot(source, roots);
  if (!root) return;
  const targetRoot = destination ? directoryMarkRoot(destination, roots) : undefined;
  if (!destination || !targetRoot || getPathIdentity(root) === getPathIdentity(targetRoot)) {
    await migrateDirectoryMarks(root, source, destination);
    return;
  }
  const sourceRules = readRules(root);
  const targetRules = readRules(targetRoot);
  const response = await invoke<{ rules: DirectoryRules; target: DirectoryRules }>("workspace.relocateDirectoryRules", {
    source: relativeTo(root, source),
    destination: relativeTo(targetRoot, destination),
    caseInsensitive: isCaseInsensitivePath(root),
    rules: sourceRules,
    target: targetRules,
  });
  const writes = [...storeRules(root, response.rules), ...storeRules(targetRoot, response.target)];
  const previous = writes.map(([key]) => [key, window.localStorage.getItem(key)] as const);
  let completed = 0;
  try {
    for (const [key, value] of writes) {
      window.localStorage.setItem(key, value);
      completed += 1;
    }
  } catch (error) {
    // Undo destination growth before restoring the larger source entries.
    for (const [key, value] of previous.slice(0, completed).reverse()) {
      if (value === null) window.localStorage.removeItem(key);
      else window.localStorage.setItem(key, value);
    }
    throw error;
  }
  for (const changedRoot of [root, targetRoot]) {
    window.dispatchEvent(new window.CustomEvent(eventName, {detail: changedRoot}));
    window.dispatchEvent(new window.CustomEvent(indexingEvent, {detail: changedRoot}));
  }
}

/**
 * Applies a directory role, exclusion or cancellation. Rust Core reduces the stored rules
 * (`workspace.reduceDirectoryAction`); this loads them, persists the result and notifies.
 */
export async function markWorkspaceDirectory(roots: readonly string[], path: string, action: DirectoryAction) {
  const root = directoryMarkRoot(path, roots);
  if (!root) throw new Error("Directory is outside the workspace");
  const rules = readRules(root);
  const reduced = await invoke<{ changed: boolean; rules: DirectoryRules }>("workspace.reduceDirectoryAction", {
    path: relativeTo(root, path),
    action,
    caseInsensitive: isCaseInsensitivePath(root),
    rules,
  });
  if (!reduced.changed) return;
  const settings = readIndexingSettings(root);
  let oldSettings: string | null;
  try { oldSettings = window.localStorage.getItem(indexingSettingsStorageKey(root)); }
  catch (cause) { throw new IndexingSettingsError("readFailed", cause); }
  try {
    // Publish only after both preference writes succeed.
    window.localStorage.setItem(indexingSettingsStorageKey(root), storeRules(root, reduced.rules, settings)[1][1]);
    writeMarks(root, reduced.rules.marks);
    window.dispatchEvent(new window.CustomEvent(indexingEvent, { detail: root }));
  } catch (error) {
    if (oldSettings === null) window.localStorage.removeItem(indexingSettingsStorageKey(root));
    else window.localStorage.setItem(indexingSettingsStorageKey(root), oldSettings);
    throw new IndexingSettingsError("writeFailed", error);
  }
}

export function useDirectoryMarks(roots: readonly string[]) {
  const rootsKey = JSON.stringify(roots);
  const [snapshot, setSnapshot] = useState<{ key: string; marks: Record<string, Marks>; error?: IndexingErrorCode }>({ key: "", marks: {} });
  useEffect(() => {
    const refresh = () => {
      try {
        setSnapshot({ key: rootsKey, marks: Object.fromEntries(roots.map((root) => [root, readDirectoryMarks(root)])) });
      } catch (error) {
        setSnapshot({ key: rootsKey, marks: {}, error: error instanceof IndexingSettingsError ? error.code : "readFailed" });
      }
    };
    refresh();
    return subscribeToIndexingChanges(roots, refresh);
  }, [rootsKey]);
  const markDirectory = useCallback((path: string, action: DirectoryAction) =>
    markWorkspaceDirectory(roots, path, action), [rootsKey]);
  const markForPath = (path: string): DirectoryMark | undefined => {
    const root = directoryMarkRoot(path, roots);
    if (!root || snapshot.key !== rootsKey) return undefined;
    const relative = getRelativePath(path, root).replace(/\\/g, "/") || ".";
    const marks = snapshot.marks[root];
    if (!marks) return undefined;
    const storedPath = Object.keys(marks).find((path) => markPathIdentity(root, path) === markPathIdentity(root, relative));
    return storedPath === undefined ? undefined : marks[storedPath];
  };
  return { markForPath, markDirectory, error: snapshot.key === rootsKey ? snapshot.error : undefined };
}
