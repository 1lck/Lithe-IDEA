import {
  indexingEvent,
  subscribeToIndexingChanges,
  indexingSettingsStorageKey,
  readIndexingSettings,
  writeIndexingSettings,
  IndexingSettingsError,
  type IndexingErrorCode,
} from "./workspace-indexing";
import { useCallback, useEffect, useState } from "react";
import { closestWorkspaceRoot } from "@/features/workspace/types/workspace-root";
import {
  getRelativePath,
  isCaseInsensitivePath,
  getPathIdentity,
  pathStartsWithRoot,
} from "@/utils/path-helpers";

export const DIRECTORY_MARKS = [
  "plain",
  "sources",
  "resources",
  "excluded",
  "module",
  "package",
] as const;
export type DirectoryMark = (typeof DIRECTORY_MARKS)[number];
type Marks = Record<string, DirectoryMark>;
const eventName = "lithe:directory-marks-changed";
const key = (root: string) =>
  `lithe.workspace-directory-marks.${getPathIdentity(root).replace(/\/+$/, "")}`;

const markPathIdentity = (root: string, relativePath: string): string => {
  const normalized = relativePath.replace(/\\/g, "/");
  return isCaseInsensitivePath(root) ? normalized.toLowerCase() : normalized;
};
export function readDirectoryMarks(root: string, storage: Storage = window.localStorage): Marks {
  let raw: string | null;
  try { raw = storage.getItem(key(root)); }
  catch (cause) { throw new IndexingSettingsError("readFailed", cause); }
  if (!raw) return {};
  let value: { version?: unknown; marks?: unknown } | null;
  try { value = JSON.parse(raw); }
  catch (cause) { throw new IndexingSettingsError("invalidSettings", cause); }
  if (
    value?.version !== 1 ||
    !value.marks ||
    Array.isArray(value.marks) ||
    typeof value.marks !== "object" ||
    !Object.entries(value.marks).every(
      ([path, mark]) =>
        !path.startsWith("/") &&
        !path.includes("\\") &&
        !path.includes(":") &&
        !path.split("/").includes("..") &&
        DIRECTORY_MARKS.includes(mark as DirectoryMark),
    )
  )
    throw new IndexingSettingsError("invalidSettings");
  return value.marks as Marks;
}
function writeMarks(root: string, marks: Marks) {
  window.localStorage.setItem(key(root), JSON.stringify({ version: 1, marks }));
  window.dispatchEvent(new window.CustomEvent(eventName, { detail: root }));
}
export function migrateDirectoryMarks(root: string, source: string, destination?: string) {
  if (!pathStartsWithRoot(source, root)) return;
  const relative = getRelativePath(source, root).replace(/\\/g, "/");
  const replacement =
    destination && pathStartsWithRoot(destination, root)
      ? getRelativePath(destination, root).replace(/\\/g, "/")
      : undefined;
  const marks = readDirectoryMarks(root);
  let changed = false;
  const sourceIdentity = markPathIdentity(root, relative);
  for (const path of Object.keys(marks)) {
    const identity = markPathIdentity(root, path);
    if (identity !== sourceIdentity && !identity.startsWith(`${sourceIdentity}/`)) continue;
    const mark = marks[path];
    delete marks[path];
    changed = true;
    if (replacement) marks[replacement + path.slice(relative.length)] = mark;
  }
  const settings = readIndexingSettings(root);
  const migrate = (path: string): string | undefined => {
    const identity = markPathIdentity(root, path);
    if (identity !== sourceIdentity && !identity.startsWith(`${sourceIdentity}/`)) return path;
    return replacement ? replacement + path.slice(relative.length) : undefined;
  };
  settings.includedDirectories = settings.includedDirectories
    .map(migrate)
    .filter((path): path is string => path !== undefined);
  settings.previousRoles = Object.fromEntries(
    Object.entries(settings.previousRoles).flatMap(([path, role]) => {
      const moved = migrate(path);
      return moved === undefined ? [] : [[moved, role]];
    }),
  );
  writeIndexingSettings(root, settings);
  if (changed) writeMarks(root, marks);
}
/** The closest workspace owns preferences, including nested added roots. */
export function directoryMarkRoot(path: string, roots: readonly string[]): string | undefined {
  return closestWorkspaceRoot(path, roots);
}

export function migrateWorkspaceDirectoryMarks(roots: readonly string[], source: string, destination?: string) {
  const root = directoryMarkRoot(source, roots);
  if (!root) return;
  const targetRoot = destination ? directoryMarkRoot(destination, roots) : undefined;
  if (!destination || !targetRoot || getPathIdentity(root) === getPathIdentity(targetRoot)) {
    migrateDirectoryMarks(root, source, destination);
    return;
  }
  const sourceRelative = getRelativePath(source, root).replace(/\\/g, "/") || ".";
  const targetRelative = getRelativePath(destination, targetRoot).replace(/\\/g, "/") || ".";
  const movePath = (path: string): string | undefined => {
    const identity = markPathIdentity(root, path);
    const sourceIdentity = markPathIdentity(root, sourceRelative);
    if (sourceIdentity !== "." && identity !== sourceIdentity && !identity.startsWith(sourceIdentity + "/")) return;
    const suffix = sourceRelative === "." ? (path === "." ? "" : "/" + path) : path.slice(sourceRelative.length);
    return targetRelative === "." ? suffix.replace(/^\//, "") || "." : targetRelative + suffix;
  };
  const sourceMarks = readDirectoryMarks(root);
  const targetMarks = readDirectoryMarks(targetRoot);
  const sourceSettings = readIndexingSettings(root);
  const targetSettings = readIndexingSettings(targetRoot);
  for (const path of Object.keys(sourceMarks)) {
    const moved = movePath(path);
    if (moved === undefined) continue;
    targetMarks[moved] = sourceMarks[path];
    delete sourceMarks[path];
  }
  sourceSettings.includedDirectories = sourceSettings.includedDirectories.filter((path) => {
    const moved = movePath(path);
    if (moved === undefined) return true;
    if (!targetSettings.includedDirectories.includes(moved)) targetSettings.includedDirectories.push(moved);
    return false;
  });
  for (const path of Object.keys(sourceSettings.previousRoles)) {
    const moved = movePath(path);
    if (moved === undefined) continue;
    targetSettings.previousRoles[moved] = sourceSettings.previousRoles[path];
    delete sourceSettings.previousRoles[path];
  }
  const writes: [string, string][] = [
    [key(root), JSON.stringify({version: 1, marks: sourceMarks})],
    [indexingSettingsStorageKey(root), JSON.stringify(sourceSettings)],
    [key(targetRoot), JSON.stringify({version: 1, marks: targetMarks})],
    [indexingSettingsStorageKey(targetRoot), JSON.stringify(targetSettings)],
  ];
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

export function markWorkspaceDirectory(roots: readonly string[], path: string, mark: DirectoryMark, cancelExclusion = false) {
  const root = directoryMarkRoot(path, roots);
  if (!root) throw new Error("Directory is outside the workspace");
  const marks = readDirectoryMarks(root);
  const relative = getRelativePath(path, root).replace(/\\/g, "/") || ".";
  const relativeIdentity = markPathIdentity(root, relative);
  const samePath = (path: string) => markPathIdentity(root, path) === relativeIdentity;
  const markKeys = Object.keys(marks).filter(samePath);
  const settings = readIndexingSettings(root);
  if (cancelExclusion) {
    if (
      Object.entries(marks).some(
        ([path, value]) =>
          value === "excluded" &&
          !samePath(path) &&
          (path === "." || relativeIdentity.startsWith(markPathIdentity(root, path) + "/")),
      )
    )
      return;
    const previousKeys = Object.keys(settings.previousRoles).filter(samePath);
    const previousKey = previousKeys.find((path) => path === relative) ?? previousKeys[0];
    const previous = previousKey === undefined ? undefined : settings.previousRoles[previousKey];
    for (const path of markKeys) delete marks[path];
    for (const path of previousKeys) delete settings.previousRoles[path];
    if (previous) marks[relative] = previous as DirectoryMark;
    if (!settings.includedDirectories.some(samePath))
      settings.includedDirectories.push(relative);
  } else {
    const previousKey = markKeys.find((path) => path === relative) ?? markKeys[0];
    const previous = previousKey === undefined ? undefined : marks[previousKey];
    if (mark === "excluded" && previous && previous !== "excluded")
      settings.previousRoles[relative] = previous;
    for (const path of markKeys) delete marks[path];
    marks[relative] = mark;
    if (mark !== "plain") settings.includedDirectories = settings.includedDirectories.filter(
      (path) => !samePath(path),
    );
  }
  const oldSettings = window.localStorage.getItem(indexingSettingsStorageKey(root));
  try {
    // Publish only after both preference writes succeed.
    window.localStorage.setItem(indexingSettingsStorageKey(root), JSON.stringify(settings));
    writeMarks(root, marks);
    window.dispatchEvent(new window.CustomEvent(indexingEvent, { detail: root }));
  } catch (error) {
    if (oldSettings === null) window.localStorage.removeItem(indexingSettingsStorageKey(root));
    else window.localStorage.setItem(indexingSettingsStorageKey(root), oldSettings);
    throw error;
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
  const markDirectory = useCallback((path: string, mark: DirectoryMark, cancelExclusion = false) => {
    markWorkspaceDirectory(roots, path, mark, cancelExclusion);
  }, [rootsKey]);
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
