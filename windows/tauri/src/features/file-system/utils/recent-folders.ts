import { invoke } from "@/platform/tauri-core";
import type { RecentFolder, RecentFolderMetadata } from "../types/recent-folders.types";

/** Rows shown by the compact title and project menus; retention is owned by Core. */
export const RECENT_PROJECT_MENU_LIMIT = 12;

interface RecentProjectEntry {
  path: string;
  lastOpenedAt?: number;
  pinned: boolean;
}

export type RecentProjectsAction =
  | { kind: "record"; path: string; openedAt: number }
  | { kind: "remove"; paths: string[] }
  | { kind: "togglePinned"; path: string }
  | { kind: "import"; paths: string[]; openedAt: number }
  | { kind: "normalize" };

export interface RecentProjectsReduction {
  entries: Required<RecentProjectEntry>[];
  added: string[];
  removed: string[];
}

function getFolderName(folderPath: string) {
  const pathSeparator = folderPath.includes("\\") ? "\\" : "/";
  return folderPath.split(pathSeparator).filter(Boolean).pop() || folderPath;
}

function formatLastOpened(timestamp: number) {
  return new Date(timestamp).toLocaleString();
}

/** Core decides which projects stay, their order, and how pins interact with capacity. */
export function reduceRecentProjects(folders: RecentFolder[], action: RecentProjectsAction) {
  return invoke<RecentProjectsReduction>("workspace.recentProjects.reduce", {
    entries: folders.map(
      (folder): RecentProjectEntry => ({
        path: folder.path,
        lastOpenedAt: folder.lastOpenedAt,
        pinned: !!folder.pinned,
      }),
    ),
    action,
  });
}

/**
 * Rebuilds the stored list in Core's order. Metadata comes from `current` (the
 * state when the reduction lands) so concurrent metadata edits are kept.
 */
export function applyRecentProjectsReduction(
  current: RecentFolder[],
  reduction: RecentProjectsReduction,
  describe: (
    path: string,
    existing: RecentFolder | undefined,
  ) => Partial<RecentFolder> = () => ({}),
): RecentFolder[] {
  const byPath = new Map(current.map((folder) => [folder.path, folder]));
  return reduction.entries.map((entry) => {
    const existing = byPath.get(entry.path);
    const base: RecentFolder = existing ?? {
      name: getFolderName(entry.path),
      path: entry.path,
      lastOpened: formatLastOpened(entry.lastOpenedAt),
    };
    const lastOpened =
      existing && existing.lastOpenedAt === entry.lastOpenedAt
        ? existing.lastOpened
        : formatLastOpened(entry.lastOpenedAt);
    return {
      ...base,
      ...describe(entry.path, existing),
      lastOpened,
      lastOpenedAt: entry.lastOpenedAt,
      pinned: entry.pinned || undefined,
    };
  });
}

/** Metadata the host attaches to a project it just opened. */
export function recordedRecentFolderMetadata(
  metadata: RecentFolderMetadata,
): (existing: RecentFolder | undefined) => Partial<RecentFolder> {
  return (existing) => ({
    activeProjectTabId: metadata.activeProjectTabId ?? existing?.activeProjectTabId,
    customIcon: metadata.customIcon ?? existing?.customIcon,
    missing: metadata.missing ?? false,
    openInNewWindow: metadata.openInNewWindow ?? existing?.openInNewWindow,
    importSourceId: metadata.importSourceId ?? existing?.importSourceId,
    importSourceName: metadata.importSourceName ?? existing?.importSourceName,
  });
}

export function updateRecentFolderMetadata(
  folders: RecentFolder[],
  folderPath: string,
  metadata: RecentFolderDisplayMetadata,
) {
  return folders.map((folder) =>
    folder.path === folderPath
      ? {
          ...folder,
          ...metadata,
        }
      : folder,
  );
}

/** Metadata edits that never change retention or order. */
export type RecentFolderDisplayMetadata = Omit<RecentFolderMetadata, "lastOpenedAt">;
