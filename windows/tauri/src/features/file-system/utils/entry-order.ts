import { invoke } from "@/platform/tauri-core";
import type { FileEntry } from "../types/app.types";

/**
 * Sibling order is owned by Rust Core (`workspace.orderEntries`, IDEA's
 * FileNameComparator). Windows enumerates local, SSH and WSL directories itself,
 * so it sends the names once per loaded directory and stores the children in
 * Core's name order. Rendering never compares names: "folders first" is a stable
 * partition of that order, which equals Core's directories-first Tree order.
 */
export function orderFileEntries<T extends Pick<FileEntry, "name" | "isDir">>(
  entries: readonly T[],
): Promise<T[]> {
  return orderEntriesBy(entries, (entry) => entry.isDir);
}

/** Orders raw provider entries (`{ name, is_dir }`) before they become tree nodes. */
export async function orderEntriesBy<T extends { name: string }>(
  entries: readonly T[],
  isDirectory: (entry: T) => boolean,
): Promise<T[]> {
  if (entries.length < 2) return [...entries];
  const { order } = await invoke<{ order: number[] }>("workspace.orderEntries", {
    entries: entries.map((entry) => ({ name: entry.name, isDirectory: isDirectory(entry) })),
    directoriesFirst: false,
  });
  return order.map((index) => entries[index]);
}

/** Directories before files, keeping Core's name order inside each group. */
export function partitionDirectoriesFirst<T extends Pick<FileEntry, "isDir">>(entries: readonly T[]): T[] {
  const directories: T[] = [];
  const files: T[] = [];
  for (const entry of entries) (entry.isDir ? directories : files).push(entry);
  return directories.length === 0 || files.length === 0 ? [...entries] : [...directories, ...files];
}
