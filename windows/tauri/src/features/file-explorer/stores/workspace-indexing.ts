import { useEffect, useState } from "react";
import type { StoreApi } from "zustand";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import type { WorkspaceRuntime } from "@/features/workspace/types/workspace-runtime.types";
import { getNativeWorkspaceRootPaths } from "@/features/file-search/utils/file-search-paths";
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

/** Coalesce both same-window writes and cross-window storage notifications. */
export function subscribeToIndexingChanges(
  roots: readonly string[] | (() => readonly string[]) | undefined,
  changed: () => void,
): () => void {
  if (typeof window === "undefined") return () => {};
  let active = true;
  let queued = false;
  const relevant = (identity?: string) => {
    const current = typeof roots === "function" ? roots() : roots;
    return !identity || !current || current.some((root) => getPathIdentity(root).replace(/\/+$/, "") === identity);
  };
  const schedule = () => {
    if (queued) return;
    queued = true;
    queueMicrotask(() => { queued = false; if (active) changed(); });
  };
  const local = (event: Event) => {
    const root = (event as CustomEvent<string>).detail;
    if (relevant(typeof root === "string" ? getPathIdentity(root).replace(/\/+$/, "") : undefined)) schedule();
  };
  const stored = (event: StorageEvent) => {
    if (event.storageArea && event.storageArea !== window.localStorage) return;
    if (event.key === null) { schedule(); return; }
    for (const prefix of ["lithe.workspace-indexing.", "lithe.workspace-directory-marks."]) {
      if (event.key.startsWith(prefix) && relevant(event.key.slice(prefix.length))) { schedule(); return; }
    }
  };
  window.addEventListener(indexingEvent, local);
  window.addEventListener("lithe:directory-marks-changed", local);
  window.addEventListener("storage", stored);
  return () => {
    active = false;
    window.removeEventListener(indexingEvent, local);
    window.removeEventListener("lithe:directory-marks-changed", local);
    window.removeEventListener("storage", stored);
  };
}

type RootLease = { root: string; revision?: number };
type IndexingOwner = {
  id: string;
  roots: Map<string, RootLease>;
  closed: boolean;
  stopPreferences: () => void;
  stopRoots?: () => void;
};
const owners = new WeakMap<WorkspaceRuntime, IndexingOwner>();
const queues = new Map<string, Promise<unknown>>();

function ownerFor(workspaceId: string): IndexingOwner {
  const runtime = workspaceRuntimeRegistry.getWorkspace(workspaceId);
  if (!runtime) throw new IndexingSettingsError("configureFailed");
  const existing = owners.get(runtime);
  if (existing) return existing;
  const owner: IndexingOwner = { id: crypto.randomUUID(), roots: new Map(), closed: false, stopPreferences: () => {} };
  owners.set(runtime, owner);
  owner.stopPreferences = subscribeToIndexingChanges(() => [...owner.roots.values()].map((lease) => lease.root), () => {
    for (const { root } of owner.roots.values()) void configureWorkspaceIndexing(root, [], false, workspaceId).catch(console.error);
  });
  runtime.disposeIndexing = async () => {
    if (owner.closed) return;
    owner.closed = true;
    owner.stopPreferences();
    owner.stopRoots?.();
    const leases = [...owner.roots.values()];
    owner.roots.clear();
    await Promise.all(leases.map((lease) => releaseLease(owner, lease)));
  };
  return owner;
}

function serialized<T>(owner: IndexingOwner, root: string, operation: () => Promise<T>): Promise<T> {
  const queueKey = JSON.stringify([owner.id, getPathIdentity(root)]);
  const task = (queues.get(queueKey) ?? Promise.resolve()).catch(() => {}).then(operation);
  queues.set(queueKey, task);
  void task.finally(() => { if (queues.get(queueKey) === task) queues.delete(queueKey); }).catch(() => {});
  return task;
}

async function releaseToken(owner: IndexingOwner, root: string, revision: number): Promise<void> {
  const response = await executeCore({ id: crypto.randomUUID(), command: "workspace.releaseIndexing", payload: { root, revision, ownerId: owner.id } });
  if (!response.ok) throw new IndexingSettingsError("configureFailed", response.error);
}
function releaseLease(owner: IndexingOwner, lease: RootLease): Promise<void> {
  return serialized(owner, lease.root, async () => {
    if (lease.revision !== undefined) {
      await releaseToken(owner, lease.root, lease.revision);
      lease.revision = undefined;
    }
  });
}

/** Workspace membership, never component mounting, owns root acquisition/release. */
export function syncWorkspaceIndexingRoots(workspaceId: string, roots: readonly string[]): void {
  const owner = ownerFor(workspaceId);
  if (owner.closed) return;
  const wanted = new Map(roots.map((root) => [getPathIdentity(root), root]));
  for (const [identity, lease] of owner.roots) {
    if (!wanted.has(identity)) {
      owner.roots.delete(identity);
      void releaseLease(owner, lease).catch(console.error);
    }
  }
  for (const [identity, root] of wanted) {
    if (!owner.roots.has(identity)) owner.roots.set(identity, { root });
  }
}

export function bindWorkspaceIndexingRoots<T extends { rootFolderPath?: string; workspaceFolders: readonly { path: string }[] }>(
  workspaceId: string, store: StoreApi<T>,
): void {
  const owner = ownerFor(workspaceId);
  let rootsKey = "";
  const update = () => {
    const state = store.getState();
    const roots = getNativeWorkspaceRootPaths(state.rootFolderPath, state.workspaceFolders);
    const next = JSON.stringify(roots);
    if (next === rootsKey) return;
    rootsKey = next;
    syncWorkspaceIndexingRoots(workspaceId, roots);
  };
  owner.stopRoots?.();
  owner.stopRoots = store.subscribe(update);
  update();
}

/** Queries share the runtime lease; a disposed tree cannot retire its workspace. */
export async function configureWorkspaceIndexing(
  root: string, paths: string[] = [], refresh = false,
  workspaceId = workspaceRuntimeRegistry.getActiveWorkspaceId(),
): Promise<IndexingStatus> {
  const owner = ownerFor(workspaceId);
  const identity = getPathIdentity(root);
  const lease = owner.roots.get(identity);
  if (!lease || owner.closed) throw new IndexingSettingsError("configureFailed");
  return serialized(owner, root, async () => {
    let supersededRetries = 0;
    while (true) {
      if (owner.closed || owner.roots.get(identity) !== lease) throw new IndexingSettingsError("configureFailed");
      const signature = JSON.stringify([readStoredValue(indexingSettingsStorageKey(root)), readStoredValue(key(root))]);
      const settings = readIndexingSettings(root);
      const raw = readStoredValue(key(root));
      const marks = raw ? JSON.parse(raw).marks : {};
      const response = await executeCore<IndexingStatus>({
        id: crypto.randomUUID(), command: "workspace.configureIndexing",
        payload: { root, ownerId: owner.id, ...settings,
          manualExcludedDirectories: Object.entries(marks ?? {}).filter(([, role]) => role === "excluded").map(([path]) => path), paths, refresh },
      });
      if (!response.ok) {
        // Another workspace owner can replace the shared scan generation.
        // These requests have no user cancellation token; re-read current
        // preferences and retry only that transient Core cancellation.
        if (response.error.code === "cancelled" && supersededRetries++ < 2) continue;
        throw new IndexingSettingsError("configureFailed", response.error);
      }
      if (owner.closed || owner.roots.get(identity) !== lease) {
        await releaseToken(owner, root, response.data.revision);
        throw new IndexingSettingsError("configureFailed");
      }
      lease.revision = response.data.revision;
      if (signature === JSON.stringify([readStoredValue(indexingSettingsStorageKey(root)), readStoredValue(key(root))])) return response.data;
    }
  });
}

export function useIndexingVersion(roots?: readonly string[]): number {
  const [version, setVersion] = useState(0);
  const rootsKey = roots === undefined ? undefined : JSON.stringify(roots);
  useEffect(() => subscribeToIndexingChanges(rootsKey === undefined ? undefined : JSON.parse(rootsKey), () => setVersion((value) => value + 1)), [rootsKey]);
  return version;
}
