import { afterEach, describe, expect, mock, test } from "bun:test";
import * as eventApi from "@tauri-apps/api/event";
import * as lspAdapter from "@/platform/lsp-core-adapter";
import type { BuildModelReview, BuildView } from "./build-systems-types";

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

const invokeMock = mock(async (command: string, args?: Record<string, unknown>) => {
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
});
mock.module("@/platform/tauri-core", () => ({ invoke: invokeMock }));
const sharedLanguageStart = mock(
  async (_args: unknown, _signal?: AbortSignal): Promise<void> => {},
);
mock.module("@/platform/lsp-core-adapter", () => ({
  ...lspAdapter,
  ensureBuildProviderLanguageSession: sharedLanguageStart,
}));

type LifecycleHandler = (event: { payload: unknown }) => void;
let lifecycleHandler: LifecycleHandler | null = null;
let fileChangeHandler: LifecycleHandler | null = null;

mock.module("@tauri-apps/api/event", () => ({
  // Keep unrelated named exports available when the pane tests share Bun's
  // module graph; only the subscription boundary belongs to this test double.
  ...eventApi,
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
const { BuildRunSession } = await import("./build-run-session");
type BuildRunNative = import("./build-run-native").BuildRunNative;
type BuildRunTerminal = import("./output/build-output-types").BuildRunTerminal;

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
  sharedLanguageStart.mockReset().mockImplementation(async () => {});
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
  // A pane suite may spy on this same export later in the process.
  invokeMock.mockClear();
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

describe("file changes during task consent and execution", () => {
  async function runningFixture() {
    resetState();
    activateWorkspace("ws-a", WORKSPACE_A);
    const initial = cargoView(WORKSPACE_A, 1);
    workspaceRuntimeRegistry.updateWorkspaceStatus("ws-a", "ready");
    initial.instances[0]!.modelSource = "command";
    initial.instances[0]!.syncDigest = "approved-source";
    nextResult = initial;
    const store = useBuildSystemsStore.getStore("ws-a");
    store.getState().actions.applyView(initial, store.getState().actions.beginRequest());
    const terminal = deferred();
    const native: BuildRunNative = {
      windowLabel: () => "test-window",
      save: async () => {},
      sync: buildSystemsService.syncInstance,
      definition: async () => ({
        tasks: [{ id: "build", displayName: "Build", scopes: ["workspace"] }],
        programs: [],
      }),
      prepare: async () => ({
        operationId: "native-watched-run",
        pluginId: catalogEntry.pluginId,
        buildSystemId: "cargo",
        workspaceRoot: WORKSPACE_A,
        root: ".",
        generation: 1,
        kind: "task",
        title: "Build",
        executesProjectCode: true,
        mayUseNetwork: true,
      }),
      execute: mock(async () => terminal.promise as Promise<BuildRunTerminal>),
      cancel: mock(async () => {
        terminal.resolve({ kind: "cancelled" });
      }),
      listen: async () => () => {},
      scheduleOutputDrain: (callback) => {
        callback();
        return () => {};
      },
    };
    const session = new BuildRunSession("ws-a", catalogEntry.pluginId, "cargo", ".", store, native);
    const releaseSession = session.attach();
    cleanups.push(() => {
      session.decide(false);
      releaseSession();
    });
    let scheduled: (() => void) | undefined;
    const releaseWatcher = await subscribeBuildSyncWatcher((callback) => {
      scheduled = callback;
      return () => {
        scheduled = undefined;
      };
    });
    cleanups.push(releaseWatcher);
    const run = session.start({
      kind: "task",
      taskId: "build",
      projectId: null,
      targetId: null,
      modelTaskId: null,
      suite: null,
      case: null,
      userArguments: [],
    });
    await flushMicrotasks();
    expect(session.getSnapshot()).toEqual(
      expect.objectContaining({ phase: "review", error: null }),
    );
    const change = async (changed: boolean) => {
      nextResult = changed
        ? {
            ...initial,
            instances: initial.instances.map((row) => ({
              ...row,
              stale: true,
              syncDigest: "edited-source",
            })),
          }
        : initial;
      fileChangeHandler!({ payload: { path: "Cargo.toml", event_type: "reloaded" } });
      expect(scheduled).toBeDefined();
      scheduled!();
      await flushMicrotasks();
    };
    return { initial, native, session, store, terminal, run, change };
  }

  test("unchanged save notifications preserve consent and the active run", async () => {
    const f = await runningFixture();
    await f.change(false);
    expect(f.session.getSnapshot().phase).toBe("review");
    expect(f.native.cancel).toHaveBeenCalledTimes(0);
    f.session.decide(true);
    await flushMicrotasks();
    expect(f.native.execute).toHaveBeenCalledTimes(1);
    await f.change(false);
    expect(f.session.getSnapshot().phase).toBe("running");
    expect(f.native.cancel).toHaveBeenCalledTimes(0);
    f.terminal.resolve({ kind: "succeeded", exitCode: 0 });
    await f.run;
  });

  test("a watched fingerprint change cancels open consent before execution", async () => {
    const f = await runningFixture();
    await f.change(true);
    f.session.decide(true);
    await f.run;
    expect(f.native.execute).toHaveBeenCalledTimes(0);
    expect(f.native.cancel).toHaveBeenCalledWith("native-watched-run");
    expect(
      f.store.getState().windows[`build-system:${catalogEntry.pluginId}:cargo`]!.instances[0]!
        .stale,
    ).toBe(true);
  });

  test("a watched fingerprint change also cancels an executing native owner", async () => {
    const f = await runningFixture();
    f.session.decide(true);
    await flushMicrotasks();
    expect(f.native.execute).toHaveBeenCalledTimes(1);
    await f.change(true);
    await f.run;
    expect(f.native.cancel).toHaveBeenCalledWith("native-watched-run");
  });

  test("approval rechecks native freshness before a debounced event is delivered", async () => {
    const f = await runningFixture();
    nextResult = {
      ...f.initial,
      instances: f.initial.instances.map((row) => ({
        ...row,
        stale: true,
        syncDigest: "edited-before-watch",
      })),
    };
    // Deliberately leave the real file event's scheduled callback pending.
    fileChangeHandler!({ payload: { path: "Cargo.toml", event_type: "reloaded" } });
    f.session.decide(true);
    await f.run;
    expect(f.native.execute).toHaveBeenCalledTimes(0);
    expect(f.native.cancel).toHaveBeenCalledWith("native-watched-run");
  });

  test("a file change while acquiring the output listener is checked before execution", async () => {
    const f = await runningFixture();
    const listener = deferred();
    f.native.listen = mock(async () => listener.promise as Promise<() => void>);
    f.session.decide(true);
    await flushMicrotasks();
    expect(f.native.listen).toHaveBeenCalledTimes(1);
    expect(f.native.execute).toHaveBeenCalledTimes(0);
    nextResult = {
      ...f.initial,
      instances: f.initial.instances.map((row) => ({
        ...row,
        stale: true,
        syncDigest: "edited-during-listener-acquisition",
      })),
    };
    // The notification remains debounced while native listener acquisition
    // completes. Its delivery must not be necessary to reject the old plan.
    fileChangeHandler!({ payload: { path: "Cargo.toml", event_type: "reloaded" } });
    listener.resolve(() => {});
    await flushMicrotasks();
    f.terminal.resolve({ kind: "succeeded", exitCode: 0 });
    await f.run;
    expect(f.native.execute).toHaveBeenCalledTimes(0);
    expect(f.native.cancel).toHaveBeenCalledWith("native-watched-run");
  });
});

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

describe("explicit command model operations", () => {
  const review = {
    operationId: "fixture-operation",
    pluginId: catalogEntry.pluginId,
    buildSystemId: "cargo",
    workspaceRoot: WORKSPACE_A,
    root: ".",
    generation: 1,
    executesProjectCode: true,
    mayUseNetwork: true,
  };

  test("caller disposal before prepare completes cancels its late native slot without approval", async () => {
    resetState();
    activateWorkspace("ws-a", WORKSPACE_A);
    const controller = new AbortController();
    cleanups.push(() => controller.abort());
    const prepared = deferCommand("declarative_plugins_build_prepare_model");
    const approve = mock(async () => true);
    const pending = buildSystemsService.loadBuildModel(
      catalogEntry.pluginId,
      "cargo",
      ".",
      approve,
      {},
      { signal: controller.signal },
    );
    await flushMicrotasks();
    controller.abort();
    prepared.resolve(review);
    expect(await pending).toBeNull();
    expect(approve).toHaveBeenCalledTimes(0);
    expect(
      invokeCalls.filter((row) => row.command === "declarative_plugins_build_cancel_operation"),
    ).toHaveLength(1);
    expect(invokeCalls.some((row) => row.command === "declarative_plugins_build_load_model")).toBe(
      false,
    );
  });

  for (const invalidation of ["generation", "selection", "option", "disable"] as const) {
    test(`${invalidation} invalidation aborts consent without relying on the bootstrap listener`, async () => {
      resetState();
      activateWorkspace("ws-a", WORKSPACE_A);
      const actions = useBuildSystemsStore.getState().actions;
      const initial = cargoView(WORKSPACE_A, 1);
      initial.instances.push({ ...initial.instances[0]!, root: "nested" });
      actions.applyView(initial, actions.beginRequest());
      const prepared = deferCommand("declarative_plugins_build_prepare_model");
      const consent = deferred();
      let signal: AbortSignal | undefined;
      const pending = buildSystemsService.loadBuildModel(
        catalogEntry.pluginId,
        "cargo",
        ".",
        (_review, input) => {
          signal = input;
          return consent.promise as Promise<boolean>;
        },
      );
      await flushMicrotasks();
      prepared.resolve(review);
      await flushMicrotasks();
      if (invalidation === "generation")
        actions.applyView({ ...initial, generation: 2 }, actions.beginRequest());
      else if (invalidation === "selection")
        actions.selectInstance(`build-system:${catalogEntry.pluginId}:cargo`, "nested");
      else if (invalidation === "option")
        actions.applyView(
          {
            ...initial,
            instances: initial.instances.map((row) => ({ ...row, optionFingerprint: "changed" })),
          },
          actions.beginRequest(),
        );
      else actions.dropPlugin(catalogEntry.pluginId);
      expect(signal!.aborted).toBe(true);
      consent.resolve(true);
      expect(await pending).toBeNull();
      expect(
        invokeCalls.some((row) => row.command === "declarative_plugins_build_load_model"),
      ).toBe(false);
    });
  }

  test("an option request invalidates open consent before its deferred response lands", async () => {
    resetState();
    activateWorkspace("ws-a", WORKSPACE_A);
    const actions = useBuildSystemsStore.getState().actions;
    const initial = cargoView(WORKSPACE_A, 1);
    actions.applyView(initial, actions.beginRequest());
    const prepared = deferCommand("declarative_plugins_build_prepare_model");
    const changed = deferCommand("declarative_plugins_build_set_option");
    const consent = deferred();
    let signal: AbortSignal | undefined;
    const pending = buildSystemsService.loadBuildModel(
      catalogEntry.pluginId,
      "cargo",
      ".",
      (_review, input) => {
        signal = input;
        return consent.promise as Promise<boolean>;
      },
    );
    await flushMicrotasks();
    prepared.resolve(review);
    await flushMicrotasks();
    const edit = setBuildOption(catalogEntry.pluginId, "cargo", ".", "release", true);
    // Invalidate at request initiation, while native has returned no new
    // fingerprint/generation that could otherwise close this old review.
    expect(signal!.aborted).toBe(true);
    consent.resolve(true);
    expect(await pending).toBeNull();
    expect(invokeCalls.some((row) => row.command === "declarative_plugins_build_load_model")).toBe(
      false,
    );
    changed.resolve({
      ...initial,
      instances: initial.instances.map((row) => ({ ...row, optionFingerprint: "changed" })),
    });
    await edit;
    expect(
      useBuildSystemsStore.getState().windows[`build-system:${catalogEntry.pluginId}:cargo`]!
        .instances[0]!.optionFingerprint,
    ).toBe("changed");
  });

  test("a review with the wrong identity is cancelled without asking for consent", async () => {
    resetState();
    activateWorkspace("ws-a", WORKSPACE_A);
    const prepared = deferCommand("declarative_plugins_build_prepare_model");
    const approve = mock(async () => true);
    const pending = buildSystemsService.loadBuildModel(
      catalogEntry.pluginId,
      "cargo",
      ".",
      approve,
    );
    const failed = pending.catch((error) => error);
    await flushMicrotasks();
    prepared.resolve({ ...review, root: "foreign" });
    expect(String(await failed)).toContain("staleContext");
    expect(approve).toHaveBeenCalledTimes(0);
    expect(
      invokeCalls.some((row) => row.command === "declarative_plugins_build_cancel_operation"),
    ).toBe(true);
  });

  test("approval exceptions release the review and report the failure", async () => {
    resetState();
    activateWorkspace("ws-a", WORKSPACE_A);
    const prepared = deferCommand("declarative_plugins_build_prepare_model");
    const pending = buildSystemsService.loadBuildModel(
      catalogEntry.pluginId,
      "cargo",
      ".",
      async () => {
        throw new Error("fixture consent failure");
      },
    );
    const failure = pending.catch((error) => error);
    await flushMicrotasks();
    prepared.resolve(review);
    expect(String(await failure)).toContain("fixture consent failure");
    expect(invokeCalls.some((row) => row.command === "declarative_plugins_build_load_model")).toBe(
      false,
    );
    expect(
      invokeCalls.filter((row) => row.command === "declarative_plugins_build_cancel_operation"),
    ).toHaveLength(1);
  });

  test("a result with the wrong operation cannot mark the model loaded", async () => {
    resetState();
    activateWorkspace("ws-a", WORKSPACE_A);
    const prepared = deferCommand("declarative_plugins_build_prepare_model");
    const loaded = deferCommand("declarative_plugins_build_load_model");
    const pending = buildSystemsService.loadBuildModel(
      catalogEntry.pluginId,
      "cargo",
      ".",
      async () => true,
    );
    const failure = pending.catch((error) => error);
    await flushMicrotasks();
    prepared.resolve(review);
    await flushMicrotasks();
    loaded.resolve({
      operationId: "wrong-operation",
      view: cargoView(WORKSPACE_A, 1),
      stderr: "late",
    });
    expect(String(await failure)).toContain("staleContext");
    expect(useBuildSystemsStore.getState().workspaceRoot).toBeNull();
  });

  test("cancellation failure is surfaced, retry remains possible, and a late load cannot apply", async () => {
    resetState();
    activateWorkspace("ws-a", WORKSPACE_A);
    const prepared = deferCommand("declarative_plugins_build_prepare_model");
    const loaded = deferCommand("declarative_plugins_build_load_model");
    const cancelled = deferCommand("declarative_plugins_build_cancel_operation");
    const pending = buildSystemsService.loadBuildModel(
      catalogEntry.pluginId,
      "cargo",
      ".",
      async () => true,
    );
    const outcome = pending.catch((error) => error);
    await flushMicrotasks();
    prepared.resolve(review);
    await flushMicrotasks();
    const stop = buildSystemsService.cancelBuildModel(review.operationId).catch((error) => error);
    await flushMicrotasks();
    cancelled.reject(new Error("fixture cancel failure"));
    expect(String(await stop)).toContain("fixture cancel failure");
    loaded.resolve({
      operationId: review.operationId,
      view: cargoView(WORKSPACE_A, 1),
      stderr: "late success",
    });
    expect(await outcome).toBeInstanceOf(buildSystemsService.BuildModelCancellationError);
    expect(useBuildSystemsStore.getState().workspaceRoot).toBeNull();
    const retried = deferCommand("declarative_plugins_build_cancel_operation");
    const retry = buildSystemsService.cancelBuildModel(review.operationId);
    await flushMicrotasks();
    retried.resolve(undefined);
    await retry;
    expect(
      invokeCalls.filter((row) => row.command === "declarative_plugins_build_cancel_operation"),
    ).toHaveLength(2);
  });

  test("Stop after model initialization cleanup failure retries the retained shared language owner", async () => {
    resetState();
    activateWorkspace("ws-a", WORKSPACE_A);
    const shared = deferred();
    const cleanup = deferred();
    const retryCleanup = mock(async () => {
      await cleanup.promise;
    });
    sharedLanguageStart.mockImplementation(async () => {
      await shared.promise;
    });
    const providerReview: BuildModelReview = {
      ...review,
      provider: {
        token: 7,
        context: {
          window: "test-window",
          workspaceRoot: WORKSPACE_A,
          generation: 1,
          pluginId: review.pluginId,
          packageIdentity: "fixture:digest",
          buildSystem: "cargo",
          instanceRoot: ".",
          instanceDirectory: WORKSPACE_A,
        },
        executesProjectCode: true,
        mayUseNetwork: true,
        launchPlan: { buildProvider: { languageServer: "fixture-language" } },
        program: {
          pluginId: review.pluginId,
          languageId: "fixture-language",
          serverPath: "fixture.exe",
          serverArgs: [],
          environment: {},
        },
      },
    };
    const native = {
      prepare: mock(async () => providerReview),
      load: mock(async () => ({
        operationId: review.operationId,
        view: cargoView(WORKSPACE_A, 1),
        stderr: "",
      })),
      cancel: mock(async () => {}),
    };
    const outcome = buildSystemsService
      .loadBuildModel(review.pluginId, "cargo", ".", async () => true, {}, { native })
      .catch((error: unknown) => error);
    try {
      await flushMicrotasks();
      expect(sharedLanguageStart).toHaveBeenCalledTimes(1);
      const stopped = buildSystemsService
        .cancelBuildModel(review.operationId)
        .catch((error: unknown) => error);
      shared.reject(Object.assign(new Error("plugin.build.cleanupFailed"), { retryCleanup }));
      expect(String(await stopped)).toContain("plugin.build.cleanupFailed");
      expect(await outcome).toBeInstanceOf(buildSystemsService.BuildModelCancellationError);
      expect(native.load).not.toHaveBeenCalled();
      let finished = false;
      const retry = buildSystemsService.cancelBuildModel(review.operationId).then(() => {
        finished = true;
      });
      await flushMicrotasks();
      expect(native.cancel).toHaveBeenCalledTimes(2);
      expect(retryCleanup).toHaveBeenCalledTimes(1);
      expect(finished).toBe(false);
      cleanup.resolve(undefined);
      await retry;
      expect(finished).toBe(true);
    } finally {
      shared.resolve(undefined);
      cleanup.resolve(undefined);
      await outcome;
      await buildSystemsService.cancelBuildModel(review.operationId);
    }
  });

  test("cancel acknowledgement is awaited and concurrent callers share the owned cleanup", async () => {
    resetState();
    activateWorkspace("ws-a", WORKSPACE_A);
    const prepared = deferCommand("declarative_plugins_build_prepare_model");
    const loaded = deferCommand("declarative_plugins_build_load_model");
    const cleanup = deferCommand("declarative_plugins_build_cancel_operation");
    const pending = buildSystemsService.loadBuildModel(
      catalogEntry.pluginId,
      "cargo",
      ".",
      async () => true,
    );
    await flushMicrotasks();
    prepared.resolve(review);
    await flushMicrotasks();
    let acknowledged = false;
    const stop = buildSystemsService.cancelBuildModel(review.operationId).then(() => {
      acknowledged = true;
    });
    const second = buildSystemsService.cancelBuildModel(review.operationId);
    await flushMicrotasks();
    expect(acknowledged).toBe(false);
    expect(
      invokeCalls.filter((row) => row.command === "declarative_plugins_build_cancel_operation"),
    ).toHaveLength(1);
    cleanup.resolve(undefined);
    await Promise.all([stop, second]);
    expect(acknowledged).toBe(true);
    loaded.resolve({
      operationId: review.operationId,
      view: cargoView(WORKSPACE_A, 1),
      stderr: "late",
    });
    expect(await pending).toBeNull();
  });

  test("Stop joins cleanup already pending after a declined review", async () => {
    resetState();
    activateWorkspace("ws-a", WORKSPACE_A);
    const prepared = deferCommand("declarative_plugins_build_prepare_model");
    const cleanup = deferCommand("declarative_plugins_build_cancel_operation");
    const pending = buildSystemsService.loadBuildModel(
      catalogEntry.pluginId,
      "cargo",
      ".",
      async () => false,
    );
    await flushMicrotasks();
    prepared.resolve(review);
    await flushMicrotasks();
    const stop = buildSystemsService.cancelBuildModel(review.operationId);
    await flushMicrotasks();
    expect(
      invokeCalls.filter((row) => row.command === "declarative_plugins_build_cancel_operation"),
    ).toHaveLength(1);
    cleanup.resolve(undefined);
    await stop;
    expect(await pending).toBeNull();
  });

  test("only confirmation starts the prepared operation and applies its matching result", async () => {
    resetState();
    activateWorkspace("ws-a", WORKSPACE_A);
    const prepared = deferCommand("declarative_plugins_build_prepare_model");
    const loaded = deferCommand("declarative_plugins_build_load_model");
    const approve = mock(async () => true);
    const pending = buildSystemsService.loadBuildModel(
      catalogEntry.pluginId,
      "cargo",
      ".",
      approve,
      { java: "C:/fixture tools/jdk/bin/java.exe" },
    );
    await flushMicrotasks();
    expect(
      invokeCalls.some((call) => call.command === "declarative_plugins_build_load_model"),
    ).toBe(false);
    prepared.resolve(review);
    await flushMicrotasks();
    expect(approve).toHaveBeenCalledTimes(1);
    const execute = invokeCalls.find(
      (call) => call.command === "declarative_plugins_build_load_model",
    );
    expect(execute?.args).toEqual({ operationId: review.operationId });
    loaded.resolve({
      operationId: review.operationId,
      view: cargoView(WORKSPACE_A, 1),
      stderr: "fixture warning",
    });
    expect((await pending)?.stderr).toBe("fixture warning");
    expect(useBuildSystemsStore.getStore("ws-a").getState().status).toBe("ready");
  });

  test("declining the review releases the native slot without execution", async () => {
    resetState();
    activateWorkspace("ws-a", WORKSPACE_A);
    const prepared = deferCommand("declarative_plugins_build_prepare_model");
    const pending = buildSystemsService.loadBuildModel(
      catalogEntry.pluginId,
      "cargo",
      ".",
      async () => false,
    );
    await flushMicrotasks();
    prepared.resolve(review);
    expect(await pending).toBeNull();
    expect(
      invokeCalls.some((call) => call.command === "declarative_plugins_build_load_model"),
    ).toBe(false);
    expect(
      invokeCalls.some((call) => call.command === "declarative_plugins_build_cancel_operation"),
    ).toBe(true);
  });

  test("switching to the welcome screen aborts consent and cancels immediately", async () => {
    resetState();
    activateWorkspace("ws-a", WORKSPACE_A);
    nextResult = cargoView(WORKSPACE_A, 1);
    const cleanup = await startBuildSystemsRuntime();
    cleanups.push(cleanup);
    await flushMicrotasks();
    const prepared = deferCommand("declarative_plugins_build_prepare_model");
    const consent = deferred();
    let signal: AbortSignal | null = null;
    const pending = buildSystemsService.loadBuildModel(
      catalogEntry.pluginId,
      "cargo",
      ".",
      (_review, nextSignal) => {
        signal = nextSignal;
        return consent.promise as Promise<boolean>;
      },
    );
    await flushMicrotasks();
    prepared.resolve(review);
    await flushMicrotasks();
    activateWorkspace("welcome", null);
    await flushMicrotasks();
    expect(signal!.aborted).toBe(true);
    expect(await pending).toBeNull();
    expect(
      invokeCalls.some((call) => call.command === "declarative_plugins_build_load_model"),
    ).toBe(false);
    consent.resolve(true);
  });

  test("workspace refresh can cancel a running load and a late model cannot update either workspace", async () => {
    resetState();
    activateWorkspace("ws-a", WORKSPACE_A);
    nextResult = cargoView(WORKSPACE_A, 1);
    const cleanup = await startBuildSystemsRuntime();
    cleanups.push(cleanup);
    await flushMicrotasks();
    const prepared = deferCommand("declarative_plugins_build_prepare_model");
    const loaded = deferCommand("declarative_plugins_build_load_model");
    const pending = buildSystemsService.loadBuildModel(
      catalogEntry.pluginId,
      "cargo",
      ".",
      async () => true,
    );
    await flushMicrotasks();
    prepared.resolve(review);
    await flushMicrotasks();
    nextResult = cargoView(WORKSPACE_B, 2);
    activateWorkspace("ws-b", WORKSPACE_B);
    await flushMicrotasks();
    expect(
      invokeCalls.some((call) => call.command === "declarative_plugins_build_cancel_operation"),
    ).toBe(true);
    expect(
      invokeCalls.some(
        (call) =>
          call.command === "declarative_plugins_build_refresh" &&
          call.args.workspaceRoot === WORKSPACE_B,
      ),
    ).toBe(true);
    loaded.resolve({
      operationId: review.operationId,
      view: cargoView(WORKSPACE_A, 99),
      stderr: "late",
    });
    expect(await pending).toBeNull();
    expect(useBuildSystemsStore.getStore("ws-a").getState().generation).toBe(1);
    expect(useBuildSystemsStore.getStore("ws-b").getState().generation).toBe(2);
  });

  test("revocation during consent cannot be approved after re-enable", async () => {
    resetState();
    activateWorkspace("ws-a", WORKSPACE_A);
    nextResult = cargoView(WORKSPACE_A, 1);
    const cleanup = await startBuildSystemsRuntime();
    cleanups.push(cleanup);
    await flushMicrotasks();
    const prepared = deferCommand("declarative_plugins_build_prepare_model");
    const consent = deferred();
    const pending = buildSystemsService.loadBuildModel(
      catalogEntry.pluginId,
      "cargo",
      ".",
      () => consent.promise as Promise<boolean>,
    );
    await flushMicrotasks();
    prepared.resolve(review);
    await flushMicrotasks();
    lifecycleHandler!({ payload: { pluginId: catalogEntry.pluginId, active: false } });
    await flushMicrotasks();
    consent.resolve(true);
    expect(await pending).toBeNull();
    expect(
      invokeCalls.some((call) => call.command === "declarative_plugins_build_load_model"),
    ).toBe(false);
    expect(useBuildSystemsStore.getStore("ws-a").getState().windows).toEqual({});
  });

  test("execution failure stays failed after native slot cleanup", async () => {
    resetState();
    activateWorkspace("ws-a", WORKSPACE_A);
    const prepared = deferCommand("declarative_plugins_build_prepare_model");
    const loaded = deferCommand("declarative_plugins_build_load_model");
    const pending = buildSystemsService.loadBuildModel(
      catalogEntry.pluginId,
      "cargo",
      ".",
      async () => true,
    );
    const failed = pending.then(
      () => null,
      (error: unknown) => error,
    );
    await flushMicrotasks();
    prepared.resolve(review);
    await flushMicrotasks();
    loaded.reject(new Error("plugin.build.outputLimit"));
    expect(String(await failed)).toContain("plugin.build.outputLimit");
    expect(useBuildSystemsStore.getStore("ws-a").getState().status).toBe("failed");
    expect(
      invokeCalls.some((call) => call.command === "declarative_plugins_build_cancel_operation"),
    ).toBe(true);
  });
});
