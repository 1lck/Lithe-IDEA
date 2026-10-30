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
export type IndexingErrorCode =
  | "invalidSettings"
  | "readFailed"
  | "writeFailed"
  | "configureFailed";
export class IndexingSettingsError extends Error {
  constructor(
    readonly code: IndexingErrorCode,
    cause?: unknown,
  ) {
    super(code, { cause });
    this.name = "IndexingSettingsError";
  }
}

function readStoredValue(key: string): string | null {
  try {
    return window.localStorage.getItem(key);
  } catch (cause) {
    throw new IndexingSettingsError("readFailed", cause);
  }
}

export function readIndexingSettings(root: string): IndexingSettings {
  const raw = readStoredValue(indexingSettingsStorageKey(root));
  if (raw === null) return { gitIgnoreEnabled: true, includedDirectories: [], previousRoles: {} };
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch (cause) {
    throw new IndexingSettingsError("invalidSettings", cause);
  }
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw new IndexingSettingsError("invalidSettings");
  const settings = value as Record<string, unknown>;
  if (
    typeof settings.gitIgnoreEnabled !== "boolean" ||
    !Array.isArray(settings.includedDirectories) ||
    !settings.includedDirectories.every((path: unknown) => typeof path === "string") ||
    (settings.previousRoles !== undefined &&
      (!settings.previousRoles ||
        typeof settings.previousRoles !== "object" ||
        Array.isArray(settings.previousRoles) ||
        !Object.values(settings.previousRoles).every((role) => typeof role === "string")))
  )
    throw new IndexingSettingsError("invalidSettings");
  return {
    gitIgnoreEnabled: settings.gitIgnoreEnabled,
    includedDirectories: settings.includedDirectories,
    previousRoles: (settings.previousRoles ?? {}) as Record<string, string>,
  };
}
export function writeIndexingSettings(root: string, settings: IndexingSettings) {
  try {
    window.localStorage.setItem(indexingSettingsStorageKey(root), JSON.stringify(settings));
  } catch (cause) {
    throw new IndexingSettingsError("writeFailed", cause);
  }
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
    const raw = readStoredValue(key(root));
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
    if (!response.ok) throw new IndexingSettingsError("configureFailed", response.error);
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
