import { afterEach, describe, expect, mock, test } from "bun:test";
import type { BuildView } from "./build-systems-types";

/**
 * Service tests for the declarative build bridge. Every request captures
 * its initiating workspace's store and sequence; these tests pin the
 * staleness contract across workspace switches, out-of-order responses,
 * late failures, and plugin revocation. All waits are deferred promises the
 * test resolves; nothing polls or sleeps.
 */

const pendingDeferred = new Set<Deferred>();
const cleanups: Array<() => void> = [];

interface Deferred {
  promise: Promise<unknown>;
  resolve: (value: unknown) => void;
  reject: (error: unknown) => void;
}

function deferred(): Deferred {
  let resolve!: (value: unknown) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<unknown>((res, rej) => {
    resolve = res as (value: unknown) => void;
    reject = rej;
  });
  const result = { promise, resolve, reject };
  pendingDeferred.add(result);
  return result;
}

const invokeCalls: Array<{ command: string; args: Record<string, unknown> }> = [];
const deferredByCommand = new Map<string, Deferred[]>();
let nextResult: unknown = null;
let nextCatalog: unknown = [];
let nextError: Error | null = null;

function deferCommand(command: string): Deferred {
  const entry = deferred();
  const queue = deferredByCommand.get(command) ?? [];
  queue.push(entry);
  deferredByCommand.set(command, queue);
  return entry;
}

mock.module("@/platform/tauri-core", () => ({
  invoke: mock(async (command: string, args?: Record<string, unknown>) => {
    invokeCalls.push({ command, args: args ?? {} });
    const queue = deferredByCommand.get(command);
    if (queue && queue.length > 0) {
      return queue.shift()!.promise;
    }
    if (command === "declarative_plugins_build_catalog") {
      return nextCatalog;
    }
    if (nextError) {
      throw nextError;
    }
    return nextResult;
  }),
}));

type LifecycleHandler = (event: { payload: unknown }) => void;
let lifecycleHandler: LifecycleHandler | null = null;
let fileChangeHandler: LifecycleHandler | null = null;

mock.module("@tauri-apps/api/event", () => ({
  listen: mock(async (event: string, handler: LifecycleHandler) => {
    if (event === "declarative-plugin-lifecycle") {
      lifecycleHandler = handler;
    } else if (event === "ln") {
      fileChangeHandler = handler;
    }
    return () => {
      if (event === "declarative-plugin-lifecycle" && lifecycleHandler === handler) {
        lifecycleHandler = null;
      }
      if (event === "ln" && fileChangeHandler === handler) {
        fileChangeHandler = null;
      }
    };
  }),
}));

mock.module("@tauri-apps/api/window", () => ({
  // Co-running suites in one bun process also resolve types and classes
  // from this module; provide the named exports they import so the mock
  // stays import-compatible outside this file.
  getCurrentWindow: () => ({ label: "test-window" }),
  Window: class Window {},
  WebviewWindow: class WebviewWindow {},
  getAllWindows: async () => [],
}));

const { workspaceRuntimeRegistry } =
  await import("@/features/workspace/runtime/workspace-runtime-registry");
const buildSystemsService = await import("./build-systems-service");
const {
  refreshBuildSystems,
  setBuildOption,
  subscribeBuildSyncWatcher,
  startBuildSystemsRuntime,
  useBuildSystemsCatalogStore,
} = buildSystemsService;
const { useBuildSystemsStore } = await import("./build-systems-store");

const WORKSPACE_A = "C:/work/a";
const WORKSPACE_B = "C:/work/b";

function activateWorkspace(id: string, path: string | null): void {
  if (path) {
    workspaceRuntimeRegistry.activateWorkspace({ id, name: id, path }, "ready");
  } else {
    workspaceRuntimeRegistry.activateWorkspace({ id, name: "Files" }, "ready");
  }
}

function resetState(): void {
  invokeCalls.length = 0;
  deferredByCommand.clear();
  nextError = null;
  nextCatalog = [];
  nextResult = null;
  for (const id of ["ws-a", "ws-b", "welcome"]) {
    useBuildSystemsStore.getStore(id).getState().actions.reset();
  }
  useBuildSystemsCatalogStore.setState({ entries: [] });
  lifecycleHandler = null;
  fileChangeHandler = null;
}

async function flushMicrotasks(): Promise<void> {
  // A fixed number of microtask turns drains the enqueue/invoke/apply chain;
  // no timer, polling loop, or wall-clock wait participates in these tests.
  for (let turn = 0; turn < 16; turn += 1) await Promise.resolve();
}

afterEach(async () => {
  buildSystemsService.cleanupBuildSystemsRuntime?.();
  for (const cleanup of cleanups.splice(0)) cleanup();
  for (const pending of pendingDeferred) pending.resolve(null);
  pendingDeferred.clear();
  await flushMicrotasks();
});

const catalogEntry = {
  pluginId: "dev.lithe.fixture.build-static-file",
  pluginDisplayName: "Static File Build Fixture",
  buildSystemId: "cargo",
  buildSystemDisplayName: "Cargo",
  icon: null,
};

function cargoView(workspaceRoot: string, generation: number): BuildView {
  return {
    generation,
    workspaceRoot,
    instances: [
      {
        pluginID: "dev.lithe.fixture.build-static-file",
        buildSystemID: "cargo",
        displayName: "Cargo",
        root: ".",
        markers: ["Cargo.toml"],
        modelSource: "static",
        model: { projects: [{ name: "fixture-app", path: "." }] },
        stale: false,
        syncDigest: null,
        optionFingerprint: "fp",
        options: [],
      },
    ],
    issues: [],
  };
}

describe("refreshBuildSystems", () => {
  test("forwards the workspace root without a forgeable window label", async () => {
    resetState();
    activateWorkspace("ws-a", WORKSPACE_A);
    nextCatalog = [catalogEntry];
    nextResult = cargoView(WORKSPACE_A, 1);

    const entries = await refreshBuildSystems();

    expect(entries).toEqual([catalogEntry]);
    const refresh = invokeCalls.find(
      (call) => call.command === "declarative_plugins_build_refresh",
    );
    expect(refresh?.args).toEqual({ workspaceRoot: WORKSPACE_A });
    expect(useBuildSystemsStore.getStore("ws-a").getState().status).toBe("ready");
  });

  test("a response landing after a switch is discarded before the next workspace detects", async () => {
    resetState();
    activateWorkspace("ws-a", WORKSPACE_A);
    const pendingA = deferCommand("declarative_plugins_build_refresh");
    const refreshA = refreshBuildSystems();
    await flushMicrotasks();

    activateWorkspace("ws-b", WORKSPACE_B);
    const pendingB = deferCommand("declarative_plugins_build_refresh");
    const refreshB = refreshBuildSystems();

    pendingA.resolve(cargoView(WORKSPACE_A, 1));
    await refreshA;
    await flushMicrotasks();
    pendingB.resolve(cargoView(WORKSPACE_B, 2));
    await refreshB;

    // A's old activation cannot publish a ready native session after a
    // switch. B is dispatched after A finishes and owns the final session.
    expect(useBuildSystemsStore.getStore("ws-a").getState().workspaceRoot).toBe(null);
    expect(useBuildSystemsStore.getStore("ws-b").getState().generation).toBe(2);
    expect(useBuildSystemsStore.getStore("ws-b").getState().workspaceRoot).toBe(WORKSPACE_B);
  });

  test("returning to a workspace drops the older of two in-flight refreshes", async () => {
    resetState();
    activateWorkspace("ws-a", WORKSPACE_A);
    const first = deferCommand("declarative_plugins_build_refresh");
    const refresh1 = refreshBuildSystems();
    await flushMicrotasks();

    activateWorkspace("ws-b", WORKSPACE_B);
    const refreshB = refreshBuildSystems();
    activateWorkspace("ws-a", WORKSPACE_A);
    const second = deferCommand("declarative_plugins_build_refresh");
    const refresh2 = refreshBuildSystems();

    first.resolve(cargoView(WORKSPACE_A, 4));
    await refresh1;
    await refreshB;
    expect(useBuildSystemsStore.getStore("ws-a").getState().generation).toBeNull();
    await flushMicrotasks();
    second.resolve(cargoView(WORKSPACE_A, 5));
    await refresh2;

    // The second request carried a newer sequence; the first is a late
    // response and must not overwrite it.
    expect(useBuildSystemsStore.getStore("ws-a").getState().generation).toBe(5);
  });

  test("a failed request does not strand the next queued refresh", async () => {
    resetState();
    activateWorkspace("ws-a", WORKSPACE_A);
    const failing = deferCommand("declarative_plugins_build_refresh");
    const refresh1 = refreshBuildSystems();
    await flushMicrotasks();

    nextCatalog = [];
    nextResult = cargoView(WORKSPACE_A, 2);
    const refresh2 = refreshBuildSystems();

    failing.reject(new Error("plugin.build.invalidSelection: late boom"));
    await refresh1;
    await refresh2;

    const state = useBuildSystemsStore.getStore("ws-a").getState();
    expect(state.status).toBe("ready");
    expect(state.error).toBeNull();
  });

  test("a failure for the latest sequence surfaces in the store", async () => {
    resetState();
    activateWorkspace("ws-a", WORKSPACE_A);
    nextError = new Error("plugin.build.invalidSelection: boom");
    await refreshBuildSystems();

    const state = useBuildSystemsStore.getStore("ws-a").getState();
    expect(state.status).toBe("failed");
    expect(state.error).toContain("plugin.build.invalidSelection");
  });

  test("without a workspace the store resets and the host is not called", async () => {
    resetState();
    activateWorkspace("welcome", null);

    await refreshBuildSystems();

    expect(
      invokeCalls.find((call) => call.command === "declarative_plugins_build_refresh"),
    ).toBeUndefined();
    expect(useBuildSystemsStore.getStore("welcome").getState().status).toBe("idle");
  });
});

describe("setBuildOption", () => {
  test("forwards the edit and applies the returned view", async () => {
    resetState();
    activateWorkspace("ws-a", WORKSPACE_A);
    nextResult = cargoView(WORKSPACE_A, 1);
    await refreshBuildSystems();
    invokeCalls.length = 0;
    nextResult = cargoView(WORKSPACE_A, 2);

    await setBuildOption("dev.lithe.fixture.build-static-file", "cargo", ".", "release", true);

    const edit = invokeCalls[0]!;
    expect(edit.command).toBe("declarative_plugins_build_set_option");
    expect(edit.args).toEqual({
      workspaceRoot: WORKSPACE_A,
      pluginId: "dev.lithe.fixture.build-static-file",
      buildSystemId: "cargo",
      root: ".",
      optionId: "release",
      value: true,
    });
    expect(useBuildSystemsStore.getStore("ws-a").getState().generation).toBe(2);
  });

  test("a late edit failure lands in the initiating store with its sequence", async () => {
    resetState();
    activateWorkspace("ws-a", WORKSPACE_A);
    nextResult = cargoView(WORKSPACE_A, 1);
    await refreshBuildSystems();

    const pending = deferCommand("declarative_plugins_build_set_option");
    const edit = setBuildOption(
      "dev.lithe.fixture.build-static-file",
      "cargo",
      ".",
      "release",
      true,
    ).catch(() => {});
    pending.reject(new Error("rejected by Core"));
    await edit;

    const state = useBuildSystemsStore.getStore("ws-a").getState();
    expect(state.status).toBe("failed");
    expect(state.error).toContain("rejected by Core");
  });
});

describe("plugin revocation", () => {
  test("the lifecycle listener filters the catalog and revokes the registry", async () => {
    resetState();
    activateWorkspace("ws-a", WORKSPACE_A);
    nextCatalog = [catalogEntry];
    nextResult = cargoView(WORKSPACE_A, 1);
    await refreshBuildSystems();
    expect(useBuildSystemsCatalogStore.getState().entries).toEqual([catalogEntry]);
    const background = useBuildSystemsStore.getStore("ws-b");
    const backgroundRequest = background.getState().actions.beginRequest();
    background.getState().actions.applyView(cargoView(WORKSPACE_B, 1), backgroundRequest);

    invokeCalls.length = 0;
    await startBuildSystemsRuntime();
    expect(lifecycleHandler).not.toBeNull();
    lifecycleHandler!({
      payload: { pluginId: "dev.lithe.fixture.build-static-file", active: false },
    });
    // Revoke runs async; flush the microtask queue.
    await flushMicrotasks();

    expect(useBuildSystemsCatalogStore.getState().entries).toEqual([]);
    expect(useBuildSystemsStore.getStore("ws-a").getState().windows).toEqual({});
    expect(
      useBuildSystemsStore.getStore("ws-b").getState().windows,
      "non-active workspace stores are revoked too",
    ).toEqual({});
    const revoke = invokeCalls.find(
      (call) => call.command === "declarative_plugins_build_plugins_changed",
    );
    expect(revoke?.args).toEqual({
      pluginId: "dev.lithe.fixture.build-static-file",
    });
    buildSystemsService.cleanupBuildSystemsRuntime?.();
  });

  test("refresh, option, and sync responses started before disable cannot revive the plugin", async () => {
    resetState();
    activateWorkspace("ws-a", WORKSPACE_A);
    nextCatalog = [catalogEntry];
    nextResult = cargoView(WORKSPACE_A, 1);
    const cleanupRuntime = await startBuildSystemsRuntime();
    await flushMicrotasks();

    const refreshResponse = deferCommand("declarative_plugins_build_refresh");
    const refresh = refreshBuildSystems();
    await flushMicrotasks();
    expect(invokeCalls[invokeCalls.length - 1]?.command).toBe("declarative_plugins_build_refresh");
    lifecycleHandler!({
      payload: { pluginId: "dev.lithe.fixture.build-static-file", active: false },
    });
    await flushMicrotasks();
    refreshResponse.resolve(cargoView(WORKSPACE_A, 2));
    await refresh;
    expect(useBuildSystemsStore.getStore("ws-a").getState().windows).toEqual({});

    lifecycleHandler!({
      payload: { pluginId: "dev.lithe.fixture.build-static-file", active: true },
    });
    nextResult = cargoView(WORKSPACE_A, 3);
    await refreshBuildSystems();
    const optionResponse = deferCommand("declarative_plugins_build_set_option");
    const option = setBuildOption(
      "dev.lithe.fixture.build-static-file",
      "cargo",
      ".",
      "release",
      true,
    );
    await flushMicrotasks();
    expect(invokeCalls[invokeCalls.length - 1]?.command).toBe(
      "declarative_plugins_build_set_option",
    );
    lifecycleHandler!({
      payload: { pluginId: "dev.lithe.fixture.build-static-file", active: false },
    });
    await flushMicrotasks();
    optionResponse.resolve(cargoView(WORKSPACE_A, 4));
    await option;
    expect(useBuildSystemsStore.getStore("ws-a").getState().windows).toEqual({});

    lifecycleHandler!({
      payload: { pluginId: "dev.lithe.fixture.build-static-file", active: true },
    });
    nextResult = cargoView(WORKSPACE_A, 5);
    await refreshBuildSystems();
    let scheduledCheck: (() => void) | null = null;
    const releaseWatcher = await subscribeBuildSyncWatcher((callback) => {
      scheduledCheck = callback;
      return () => {
        scheduledCheck = null;
      };
    });
    cleanups.push(releaseWatcher);
    const syncResponse = deferCommand("declarative_plugins_build_sync_check");
    fileChangeHandler!({ payload: { path: "Cargo.toml", event_type: "reloaded" } });
    scheduledCheck!();
    await flushMicrotasks();
    expect(invokeCalls[invokeCalls.length - 1]?.command).toBe(
      "declarative_plugins_build_sync_check",
    );
    lifecycleHandler!({
      payload: { pluginId: "dev.lithe.fixture.build-static-file", active: false },
    });
    await flushMicrotasks();
    syncResponse.resolve(cargoView(WORKSPACE_A, 6));
    await flushMicrotasks();
    expect(useBuildSystemsStore.getStore("ws-a").getState().windows).toEqual({});

    cleanupRuntime();
  });

  test("a catalog fetch that started before a disable never overwrites it", async () => {
    resetState();
    activateWorkspace("ws-a", WORKSPACE_A);
    const staleFetch = deferCommand("declarative_plugins_build_catalog");
    const fetchPromise = refreshBuildSystems();

    // The post-disable catalog lands first with the plugin removed.
    nextCatalog = [];
    const { fetchBuildCatalog: fetchAgain } = await import("./build-systems-service");
    const fresh = await fetchAgain();
    expect(fresh).toEqual([]);
    expect(useBuildSystemsCatalogStore.getState().entries).toEqual([]);

    staleFetch.resolve([catalogEntry]);
    await fetchPromise;
    expect(useBuildSystemsCatalogStore.getState().entries).toEqual([]);
  });
});

describe("workspace activation", () => {
  test("returning A to B to A realigns native commands before edits and sync", async () => {
    resetState();
    activateWorkspace("ws-a", WORKSPACE_A);
    nextResult = cargoView(WORKSPACE_A, 1);
    const cleanupRuntime = await startBuildSystemsRuntime();
    await flushMicrotasks();

    nextResult = cargoView(WORKSPACE_B, 2);
    activateWorkspace("ws-b", WORKSPACE_B);
    await flushMicrotasks();
    nextResult = cargoView(WORKSPACE_A, 3);
    activateWorkspace("ws-a", WORKSPACE_A);
    await flushMicrotasks();

    const refreshRoots = invokeCalls
      .filter((call) => call.command === "declarative_plugins_build_refresh")
      .map((call) => call.args.workspaceRoot);
    expect(refreshRoots).toEqual([WORKSPACE_A, WORKSPACE_B, WORKSPACE_A]);
    expect(useBuildSystemsStore.getStore("ws-a").getState().status).toBe("ready");

    nextResult = cargoView(WORKSPACE_A, 4);
    await setBuildOption("dev.lithe.fixture.build-static-file", "cargo", ".", "release", true);
    const edit = [...invokeCalls]
      .reverse()
      .find((call) => call.command === "declarative_plugins_build_set_option");
    expect(edit?.args.workspaceRoot).toBe(WORKSPACE_A);

    let scheduledCheck: (() => void) | null = null;
    const releaseWatcher = await subscribeBuildSyncWatcher((callback) => {
      scheduledCheck = callback;
      return () => {
        scheduledCheck = null;
      };
    });
    cleanups.push(releaseWatcher);
    nextResult = cargoView(WORKSPACE_A, 5);
    fileChangeHandler!({ payload: { path: "Cargo.toml", event_type: "reloaded" } });
    scheduledCheck!();
    await flushMicrotasks();
    const sync = [...invokeCalls]
      .reverse()
      .find((call) => call.command === "declarative_plugins_build_sync_check");
    expect(sync?.args.workspaceRoot).toBe(WORKSPACE_A);

    cleanupRuntime();
  });
});
