import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import * as core from "@/core/lithe-core-client";
import { workspaceRuntimeRegistry as registry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { installHappyDom } from "@/test-utils/happy-dom";
import {
  IndexingSettingsError,
  indexingSettingsStorageKey,
  readIndexingSettings,
  writeIndexingSettings,
  configureWorkspaceIndexing,
  syncWorkspaceIndexingRoots,
  subscribeToIndexingChanges,
} from "./workspace-indexing";

let restore: () => void;
const coreReply = <T,>(id: string, data: unknown): core.CoreResponse<T> => ({id, ok: true, data: data as T});
beforeEach(() => {
  restore = installHappyDom();
});
afterEach(() => restore());

test.each([
  "",
  "broken",
  "null",
  "[]",
  "{}",
  '{"gitIgnoreEnabled":true,"includedDirectories":[1]}',
  '{"gitIgnoreEnabled":true,"includedDirectories":[],"previousRoles":null}',
  '{"gitIgnoreEnabled":true,"includedDirectories":[],"previousRoles":{"src":1}}',
])("invalid indexing settings are classified and preserved: %s", (raw) => {
  const key = indexingSettingsStorageKey("C:/fixture");
  window.localStorage.setItem(key, raw);
  expect(() => readIndexingSettings("C:/fixture")).toThrow(IndexingSettingsError);
  try {
    readIndexingSettings("C:/fixture");
  } catch (cause) {
    expect((cause as IndexingSettingsError).code).toBe("invalidSettings");
  }
  expect(window.localStorage.getItem(key)).toBe(raw);
});

test("storage failures expose stable codes and preserve the saved preference", () => {
  const settings = { gitIgnoreEnabled: false, includedDirectories: ["keep"], previousRoles: {} };
  writeIndexingSettings("C:/fixture", settings);
  const descriptor = Object.getOwnPropertyDescriptor(window, "localStorage");
  const storage = window.localStorage;
  let failRead = true;
  Object.defineProperty(window, "localStorage", {
    configurable: true,
    value: {
      getItem: (key: string) => {
        if (failRead) throw new Error("fixture read");
        return storage.getItem(key);
      },
      setItem: () => {
        throw new Error("fixture quota");
      },
    },
  });
  try {
    expect(() => readIndexingSettings("C:/fixture")).toThrow("readFailed");
    failRead = false;
    expect(() =>
      writeIndexingSettings("C:/fixture", { ...settings, gitIgnoreEnabled: true }),
    ).toThrow("writeFailed");
  } finally {
    if (descriptor) Object.defineProperty(window, "localStorage", descriptor);
    else Reflect.deleteProperty(window, "localStorage");
  }
  expect(readIndexingSettings("C:/fixture")).toEqual(settings);
});

test("view subscribers do not own policy leases and shared roots use distinct runtime owners", async () => {
  const calls: Array<{command: string; payload?: unknown}> = [];
  let revision = 0;
  const execute = spyOn(core, "executeCore").mockImplementation(async <TData, TPayload>(request: core.CoreRequest<TPayload>) => {
    calls.push(request);
    return coreReply<TData>(request.id, { revision: ++revision, excludedDirectories: {}, gitIgnoreFailed: false });
  });
  const first = registry.ensureWorkspace({id: "lease-first", name: "first"});
  const second = registry.ensureWorkspace({id: "lease-second", name: "second"});
  try {
    for (const id of [first.descriptor.id, second.descriptor.id]) syncWorkspaceIndexingRoots(id, ["C:/shared"]);
    await configureWorkspaceIndexing("C:/shared", [], false, first.descriptor.id);
    await configureWorkspaceIndexing("C:/shared", [], false, second.descriptor.id);
    const owners = calls.map((call) => (call.payload as {ownerId: string}).ownerId);
    expect(owners[0]).not.toBe(owners[1]);
    const unsubscribeView = subscribeToIndexingChanges(["C:/shared"], () => {});
    unsubscribeView();
    expect(calls.filter((call) => call.command === "workspace.releaseIndexing")).toHaveLength(0);
    await first.disposeIndexing?.();
    const release = calls.find((call) => call.command === "workspace.releaseIndexing");
    expect((release?.payload as {ownerId: string}).ownerId).toBe(owners[0]);
    await configureWorkspaceIndexing("C:/shared", [], false, second.descriptor.id);
    expect((calls[calls.length - 1]?.payload as {ownerId: string}).ownerId).toBe(owners[1]);
  } finally {
    await first.disposeIndexing?.(); await second.disposeIndexing?.();
    registry.removeWorkspace(first.descriptor.id); registry.removeWorkspace(second.descriptor.id);
    execute.mockRestore();
  }
});

test("removing a root reclaims a policy installed after the removal", async () => {
  let started!: () => void;
  const began = new Promise<void>((resolve) => { started = resolve; });
  let finish!: (value: {id: string; ok: true; data: {revision: number; excludedDirectories: {}; gitIgnoreFailed: boolean}}) => void;
  const pending = new Promise<{id: string; ok: true; data: {revision: number; excludedDirectories: {}; gitIgnoreFailed: boolean}}>((resolve) => { finish = resolve; });
  const calls: string[] = [];
  const execute = spyOn(core, "executeCore").mockImplementation(async <TData, TPayload>(request: core.CoreRequest<TPayload>) => {
    calls.push(request.command);
    if (request.command === "workspace.configureIndexing") { started(); return coreReply<TData>(request.id, (await pending).data); }
    return coreReply<TData>(request.id, {released: true});
  });
  const runtime = registry.ensureWorkspace({id: "lease-late", name: "late"});
  syncWorkspaceIndexingRoots(runtime.descriptor.id, ["C:/late"]);
  const query = configureWorkspaceIndexing("C:/late", [], false, runtime.descriptor.id);
  try {
    await began;
    syncWorkspaceIndexingRoots(runtime.descriptor.id, []);
    finish({id: "late", ok: true, data: {revision: 41, excludedDirectories: {}, gitIgnoreFailed: false}});
    await expect(query).rejects.toThrow(IndexingSettingsError);
    expect(calls).toEqual(["workspace.configureIndexing", "workspace.releaseIndexing"]);
  } finally {
    finish({id: "late", ok: true, data: {revision: 41, excludedDirectories: {}, gitIgnoreFailed: false}});
    await query.catch(() => {}); await runtime.disposeIndexing?.();
    registry.removeWorkspace(runtime.descriptor.id); execute.mockRestore();
  }
}, 2000);

test.each([true, false])("superseded configuration retries are bounded, success=%s", async (succeeds) => {
  const runtime = registry.ensureWorkspace({id: `lease-superseded-${succeeds}`, name: "superseded"});
  syncWorkspaceIndexingRoots(runtime.descriptor.id, ["C:/superseded"]);
  let attempts = 0;
  const execute = spyOn(core, "executeCore").mockImplementation(async <TData, TPayload>(request: core.CoreRequest<TPayload>) => {
    if (request.command !== "workspace.configureIndexing") return coreReply<TData>(request.id, {released: true});
    attempts++;
    if (!succeeds || attempts < 3) return {id: request.id, ok: false, error: {code: "cancelled", message: "superseded"}};
    return coreReply<TData>(request.id, {revision: 42, excludedDirectories: {}, gitIgnoreFailed: false});
  });
  try {
    const query = configureWorkspaceIndexing("C:/superseded", [], false, runtime.descriptor.id);
    if (succeeds) expect((await query).revision).toBe(42);
    else await expect(query).rejects.toThrow(IndexingSettingsError);
    expect(attempts).toBe(3);
  } finally {
    await runtime.disposeIndexing?.(); registry.removeWorkspace(runtime.descriptor.id); execute.mockRestore();
  }
});

test("root removal during a superseded configuration prevents a retry", async () => {
  const runtime = registry.ensureWorkspace({id: "lease-retry-removed", name: "removed"});
  syncWorkspaceIndexingRoots(runtime.descriptor.id, ["C:/removed"]);
  let attempts = 0;
  const execute = spyOn(core, "executeCore").mockImplementation(async <TData, TPayload>(request: core.CoreRequest<TPayload>) => {
    if (request.command !== "workspace.configureIndexing") return coreReply<TData>(request.id, {released: true});
    attempts++;
    syncWorkspaceIndexingRoots(runtime.descriptor.id, []);
    return {id: request.id, ok: false, error: {code: "cancelled", message: "superseded"}};
  });
  try {
    await expect(configureWorkspaceIndexing("C:/removed", [], false, runtime.descriptor.id)).rejects.toThrow(IndexingSettingsError);
    expect(attempts).toBe(1);
  } finally {
    await runtime.disposeIndexing?.(); registry.removeWorkspace(runtime.descriptor.id); execute.mockRestore();
  }
});

test("cross-window storage changes are root-filtered, coalesced and cancelled on disposal", async () => {
  let changes = 0;
  const stop = subscribeToIndexingChanges(["C:/fixture"], () => changes++);
  try {
    window.dispatchEvent(new window.StorageEvent("storage", {key: indexingSettingsStorageKey("D:/other")}));
    await Promise.resolve(); expect(changes).toBe(0);
    window.dispatchEvent(new window.StorageEvent("storage", {key: indexingSettingsStorageKey("C:/fixture")}));
    window.dispatchEvent(new window.StorageEvent("storage", {key: "lithe.workspace-directory-marks.c:/fixture"}));
    await Promise.resolve(); expect(changes).toBe(1);
    window.dispatchEvent(new window.StorageEvent("storage", {key: indexingSettingsStorageKey("C:/fixture")}));
    stop(); await Promise.resolve(); expect(changes).toBe(1);
  } finally { stop(); }
});

test("background project inventory keeps its owner when another workspace becomes active", async () => {
  const previous = registry.getActiveWorkspaceId();
  const first = registry.ensureWorkspace({id: "inventory-owner-first", name: "first"});
  const second = registry.ensureWorkspace({id: "inventory-owner-second", name: "second"});
  const store = useFileSystemStore.getStore(first.descriptor.id);
  store.setState({rootFolderPath: "C:/inventory-first", workspaceFolders: []});
  useFileSystemStore.getStore(second.descriptor.id).setState({rootFolderPath: "D:/inventory-second", workspaceFolders: []});
  registry.activateWorkspace(first.descriptor, "ready");
  const owners: string[] = [];
  const execute = spyOn(core, "executeCore").mockImplementation(async <TData, TPayload>(request: core.CoreRequest<TPayload>) => {
    if (request.command === "workspace.configureIndexing") {
      owners.push((request.payload as {ownerId: string}).ownerId);
      return coreReply<TData>(request.id, {revision: 1, excludedDirectories: {}, gitIgnoreFailed: false});
    }
    if (request.command === "workspace.snapshot") {
      registry.activateWorkspace(second.descriptor, "ready");
      return coreReply<TData>(request.id, {files: ["Keep.ts"], incompleteDirectories: []});
    }
    return coreReply<TData>(request.id, {released: true});
  });
  try {
    const files = await store.getState().getAllProjectFiles();
    expect(files.map((file) => file.path.replace(/\\/g, "/"))).toEqual(["C:/inventory-first/Keep.ts"]);
    expect(owners).toHaveLength(2);
    expect(new Set(owners).size).toBe(1);
  } finally {
    await first.disposeIndexing?.(); await second.disposeIndexing?.();
    registry.removeWorkspace(first.descriptor.id); registry.removeWorkspace(second.descriptor.id);
    registry.activateWorkspace({id: previous, name: "restored"}); execute.mockRestore();
  }
});
