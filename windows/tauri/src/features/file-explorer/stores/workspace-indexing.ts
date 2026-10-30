import { useEffect, useState } from "react";
import { executeCore } from "@/core/lithe-core-client";
import { getPathIdentity } from "@/utils/path-helpers";

export interface IndexingSettings {
  gitIgnoreEnabled: boolean;
  includedDirectories: string[];
  previousRoles: Record<string, string>;
}
export interface IndexingStatus {
  revision: number;
  excludedDirectories: Record<string, string>;
  gitIgnoreFailed: boolean;
}
export const indexingEvent = "lithe:workspace-indexing-changed";
const key = (root: string) =>
  `lithe.workspace-directory-marks.${getPathIdentity(root).replace(/\/+$/, "")}`;
export const indexingSettingsStorageKey = (root: string) =>
  `lithe.workspace-indexing.${getPathIdentity(root).replace(/\/+$/, "")}`;
export function readIndexingSettings(root: string): IndexingSettings {
  const raw = window.localStorage.getItem(indexingSettingsStorageKey(root));
  if (!raw) return { gitIgnoreEnabled: true, includedDirectories: [], previousRoles: {} };
  const value = JSON.parse(raw);
  if (
    typeof value.gitIgnoreEnabled !== "boolean" ||
    !Array.isArray(value.includedDirectories) ||
    !value.includedDirectories.every((path: unknown) => typeof path === "string")
  )
    throw new Error("Invalid indexing settings");
  return { ...value, previousRoles: value.previousRoles ?? {} };
}
export function writeIndexingSettings(root: string, settings: IndexingSettings) {
  window.localStorage.setItem(indexingSettingsStorageKey(root), JSON.stringify(settings));
  window.dispatchEvent(new window.CustomEvent(indexingEvent, { detail: root }));
}

/** Serialize policy installation per root, so older settings cannot win an async race. */
const queues = new Map<string, Promise<unknown>>();
const revisions = new Map<string, number>();
export async function configureWorkspaceIndexing(
  root: string,
  paths: string[] = [],
  refresh = false,
): Promise<IndexingStatus> {
  const identity = getPathIdentity(root);
  const operation = async () => {
    const settings = readIndexingSettings(root);
    const raw = window.localStorage.getItem(key(root));
    const marks = raw ? JSON.parse(raw).marks : {};
    const response = await executeCore<IndexingStatus>({
      id: crypto.randomUUID(),
      command: "workspace.configureIndexing",
      payload: {
        root,
        ...settings,
        manualExcludedDirectories: Object.entries(marks ?? {})
          .filter(([, role]) => role === "excluded")
          .map(([path]) => path),
        paths,
        refresh,
      },
    });
    if (!response.ok) throw new Error(response.error.message);
    revisions.set(identity, response.data.revision);
    return response.data;
  };
  const task = (queues.get(identity) ?? Promise.resolve()).catch(() => {}).then(operation);
  queues.set(identity, task);
  try {
    return await task;
  } finally {
    if (queues.get(identity) === task) queues.delete(identity);
  }
}

/** React consumers retire visible results when either source of policy changes. */
export function useIndexingVersion(): number {
  const [version, setVersion] = useState(0);
  useEffect(() => {
    const changed = () => setVersion((value) => value + 1);
    window.addEventListener(indexingEvent, changed);
    window.addEventListener("lithe:directory-marks-changed", changed);
    return () => {
      window.removeEventListener(indexingEvent, changed);
      window.removeEventListener("lithe:directory-marks-changed", changed);
    };
  }, []);
  return version;
}

export async function releaseWorkspaceIndexing(root: string): Promise<void> {
  const identity = getPathIdentity(root);
  const task = (queues.get(identity) ?? Promise.resolve())
    .catch(() => {})
    .then(async () => {
      const revision = revisions.get(identity);
      if (revision === undefined) return;
      await executeCore({
        id: crypto.randomUUID(),
        command: "workspace.releaseIndexing",
        payload: { root, revision },
      });
      revisions.delete(identity);
    });
  queues.set(identity, task);
  try {
    await task;
  } finally {
    if (queues.get(identity) === task) queues.delete(identity);
  }
}
