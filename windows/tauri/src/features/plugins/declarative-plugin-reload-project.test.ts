import { afterEach, expect, mock, test } from "bun:test";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { useBuildSystemsStore } from "@/features/build-systems/build-systems-store";
import type { BuildModelReview, BuildView } from "@/features/build-systems/build-systems-types";
import { PluginSettingsReloads, type PluginReloadReceipt } from "./declarative-plugin-reload";

const calls: Array<[string, any]> = [];
let nativeReload = async (): Promise<{ view: BuildView }> => ({ view: view() });
let nativeCancel = async (_operationId: string) => {};
let published = view();
const invoke = mock(async (command: string, args: any) => {
  calls.push([command, args]);
  if (command === "declarative_plugins_reload_settings") return nativeReload();
  if (command === "declarative_plugins_prepare_settings_reload_model") return review(args.root);
  if (command === "declarative_plugins_build_load_model")
    return { operationId: args.operationId, view: published, stderr: "" };
  if (command === "declarative_plugins_build_cancel_operation")
    return nativeCancel(args.operationId);
  throw new Error(`Unexpected command: ${command}`);
});
mock.module("@/platform/tauri-core", () => ({ invoke }));
// Exercise the production model service, consent, publication and cleanup.
const { reloadProjectSettings } = await import("./declarative-plugin-reload-project");
const receipt: PluginReloadReceipt = {
  pluginId: "example.plugin",
  workspacePath: "/fixture/project",
  scope: "project",
  expectedIdentity: "saved",
  expectedPackageIdentity: "accepted",
  project: { workspaceId: "project-a", registration: 7, windowIncarnation: 1 },
};
function view(): BuildView {
  return { generation: 9, workspaceRoot: "/fixture/project", issues: [], instances: [] };
}
function models(): BuildView {
  const result = view();
  result.instances = ["command", "provider", "static"].map((source, index) => ({
    pluginID: "example.plugin",
    buildSystemID: `fixture-${index}`,
    displayName: "Fixture",
    root: `root-${index}`,
    modelSource: source as "command",
    markers: [],
    options: [],
    stale: false,
    syncDigest: null,
    optionFingerprint: null,
  }));
  result.instances.push({ ...result.instances[0]!, pluginID: "other.plugin", root: "other" });
  return result;
}
function review(root: string): BuildModelReview {
  return {
    operationId: `model-${root}`,
    pluginId: receipt.pluginId,
    buildSystemId: `fixture-${root.slice(-1)}`,
    workspaceRoot: receipt.workspacePath,
    root,
    generation: 9,
    executesProjectCode: true,
    mayUseNetwork: false,
  };
}
function open() {
  workspaceRuntimeRegistry.activateWorkspace(
    { id: "project-a", name: "Project", path: receipt.workspacePath },
    "ready",
  );
}
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}
afterEach(() => {
  workspaceRuntimeRegistry.resetForTests();
  calls.length = 0;
  nativeReload = async () => ({ view: view() });
  nativeCancel = async () => {};
});

test("project reload forwards the exact native receipt and applies only its own build store", async () => {
  open();
  workspaceRuntimeRegistry.ensureWorkspace(
    { id: "project-b", name: "Other", path: "/fixture/other" },
    "ready",
  );
  const other = useBuildSystemsStore.getStore("project-b").getState();
  await reloadProjectSettings(receipt);
  expect(calls).toEqual([["declarative_plugins_reload_settings", receipt]]);
  expect(useBuildSystemsStore.getStore("project-a").getState().generation).toBe(9);
  expect(useBuildSystemsStore.getStore("project-b").getState()).toBe(other);
}, 1000);

test("closing and reopening the same path during native drain cannot publish into the replacement store", async () => {
  open();
  const gate = deferred<{ view: BuildView }>();
  nativeReload = () => gate.promise;
  const pending = reloadProjectSettings(receipt).then(() => "success", String);
  try {
    workspaceRuntimeRegistry.activateWorkspace({ id: "other", name: "Other" }, "ready");
    workspaceRuntimeRegistry.removeWorkspace("project-a");
    open();
    const replacement = useBuildSystemsStore.getStore("project-a");
    gate.resolve({ view: view() });
    expect(await pending).toContain("staleContext");
    expect(replacement.getState().generation).toBeNull();
    expect(calls.map(([command]) => command)).toEqual(["declarative_plugins_reload_settings"]);
  } finally {
    gate.resolve({ view: view() });
    await pending;
  }
}, 1000);

test("CAS or package rejection never reloads models or publishes a view", async () => {
  open();
  for (const code of [
    "plugin.settings.conflict",
    "plugin.settings.packageChanged",
    "plugin.settings.reloadStopFailed",
  ]) {
    nativeReload = async () => {
      throw new Error(code);
    };
    await expect(reloadProjectSettings(receipt)).rejects.toThrow(code);
    expect(useBuildSystemsStore.getStore("project-a").getState().generation).toBeNull();
  }
  expect(calls.every(([command]) => command === "declarative_plugins_reload_settings")).toBe(true);
}, 1000);

test("a pre-aborted project reload never dispatches native work", async () => {
  open();
  const controller = new AbortController();
  controller.abort();
  await expect(reloadProjectSettings(receipt, undefined, controller.signal)).rejects.toThrow(
    "reloadCancelled",
  );
  expect(calls).toEqual([]);
}, 1000);

test("aborting before the native boundary returns prevents model preparation and frontend publication", async () => {
  open();
  const gate = deferred<{ view: BuildView }>();
  const controller = new AbortController();
  const modelPhase = mock(() => {});
  nativeReload = () => gate.promise;
  const pending = reloadProjectSettings(receipt, undefined, controller.signal, modelPhase).then(
    () => "success",
    String,
  );
  try {
    controller.abort();
    gate.resolve({ view: models() });
    expect(await pending).toContain("reloadCancelled");
    expect(modelPhase.mock.calls).toHaveLength(0);
    expect(calls.map(([command]) => command)).toEqual(["declarative_plugins_reload_settings"]);
    expect(useBuildSystemsStore.getStore("project-a").getState().generation).toBeNull();
  } finally {
    gate.resolve({ view: models() });
    await pending;
  }
}, 1000);

test("command and Provider models use real model service consent and saved-receipt preparation", async () => {
  open();
  published = models();
  nativeReload = async () => ({ view: published });
  const approve = mock(async () => true);
  await reloadProjectSettings(receipt, approve);
  expect(approve.mock.calls).toHaveLength(2);
  expect(
    calls
      .filter(([command]) => command === "declarative_plugins_prepare_settings_reload_model")
      .map(([, args]) => args),
  ).toEqual([
    { receipt, buildSystemId: "fixture-0", root: "root-0", runtimeExecutables: {} },
    { receipt, buildSystemId: "fixture-1", root: "root-1", runtimeExecutables: {} },
  ]);
  expect(
    calls.filter(([command]) => command === "declarative_plugins_build_load_model"),
  ).toHaveLength(2);
  expect(calls.some(([command]) => command.includes("cancel"))).toBe(false);
}, 1000);

test("declining model consent retains reload retry until failed native cleanup is reclaimed", async () => {
  open();
  published = models();
  published.instances = published.instances.slice(0, 1);
  nativeReload = async () => ({ view: published });
  let fail = true;
  nativeCancel = async () => {
    if (fail) throw new Error("cleanup still running");
  };
  const owner = new PluginSettingsReloads({
    reload: reloadProjectSettings,
    refresh: async () => {},
  });
  owner.require(receipt);
  const key = owner.key(receipt);
  try {
    await owner.confirm(key, async () => false);
    expect(owner.state(key)?.error).toContain("cleanup still running");
    expect(owner.canPostpone(key)).toBe(false);
    expect(calls.some(([command]) => command === "declarative_plugins_build_load_model")).toBe(
      false,
    );
    fail = false;
    const retryStart = calls.length;
    await owner.confirm(key, async () => true);
    expect(owner.states()).toEqual([]);
    expect(calls[retryStart]?.[0]).toBe("declarative_plugins_build_cancel_operation");
    expect(calls[retryStart + 1]?.[0]).toBe("declarative_plugins_reload_settings");
  } finally {
    fail = false;
    await owner.confirm(key, async () => false);
  }
}, 1000);

test("cancellation during real model approval waits for native cleanup before releasing the notice", async () => {
  open();
  published = models();
  published.instances = published.instances.slice(0, 1);
  nativeReload = async () => ({ view: published });
  const entered = deferred<void>();
  const consent = deferred<boolean>();
  const cleaning = deferred<void>();
  const cleaned = deferred<void>();
  nativeCancel = async () => {
    cleaning.resolve();
    await cleaned.promise;
  };
  const owner = new PluginSettingsReloads({
    reload: reloadProjectSettings,
    refresh: async () => {},
  });
  owner.require(receipt);
  const key = owner.key(receipt);
  const pending = owner.confirm(key, async () => {
    entered.resolve();
    return consent.promise;
  });
  try {
    await entered.promise;
    owner.cancel(key);
    await cleaning.promise;
    expect(owner.state(key)?.busy).toBe(true);
    expect(calls.some(([command]) => command === "declarative_plugins_build_load_model")).toBe(
      false,
    );
    cleaned.resolve();
    consent.resolve(false);
    await pending;
    expect(owner.state(key)?.error).toContain("reloadCancelled");
    expect(owner.canPostpone(key)).toBe(true);
  } finally {
    consent.resolve(false);
    cleaned.resolve();
    await pending;
  }
}, 1000);
