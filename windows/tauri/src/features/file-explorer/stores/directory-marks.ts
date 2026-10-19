import { useCallback, useEffect, useState } from "react";
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
  const raw = storage.getItem(key(root));
  if (!raw) return {};
  const value = JSON.parse(raw);
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
    throw new Error("Invalid directory marks");
  return value.marks;
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
  if (changed) writeMarks(root, marks);
}
export function useDirectoryMarks(root?: string) {
  const [snapshot, setSnapshot] = useState<{ root?: string; marks: Marks; error?: string }>({
    marks: {},
  });
  useEffect(() => {
    const refresh = () => {
      try {
        setSnapshot({ root, marks: root ? readDirectoryMarks(root) : {} });
      } catch (error) {
        setSnapshot({ root, marks: {}, error: String(error) });
      }
    };
    refresh();
    window.addEventListener(eventName, refresh);
    window.addEventListener("storage", refresh);
    return () => {
      window.removeEventListener(eventName, refresh);
      window.removeEventListener("storage", refresh);
    };
  }, [root]);
  const markDirectory = useCallback(
    (path: string, mark: DirectoryMark) => {
      if (!root || !pathStartsWithRoot(path, root))
        throw new Error("Directory is outside the workspace");
      const marks = readDirectoryMarks(root);
      const relative = getRelativePath(path, root).replace(/\\/g, "/") || ".";
      if (mark === "plain") delete marks[relative];
      else marks[relative] = mark;
      writeMarks(root, marks);
    },
    [root],
  );
  return {
    marks: snapshot.root === root ? snapshot.marks : {},
    error: snapshot.root === root ? snapshot.error : undefined,
    markDirectory,
  };
}
