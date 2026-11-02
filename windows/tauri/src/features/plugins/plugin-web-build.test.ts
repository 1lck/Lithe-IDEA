import { afterEach, expect, spyOn, test } from "bun:test";
import * as events from "@tauri-apps/api/event";
import * as windows from "@tauri-apps/api/window";
import * as native from "@/platform/tauri-core";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { useBuildSystemsStore } from "@/features/build-systems/build-systems-store";
import type { BuildView } from "@/features/build-systems/build-systems-types";
import {
  initializePluginWebBuildListener,
  type PluginWebBuildPort,
  type PluginWebBuildRequest,
  type PluginWebBuildWorkspace,
} from "./plugin-web-build";

const cleanups: Array<() => void> = [];
const deferred: Array<{ resolve: (value: BuildView | null) => void }> = [];
let sequence = 0;
const PLUGIN = "fixture.web.build";

async function flush() {
  // Drain only the known handle -> apply -> finally promise chain.
  for (let turn = 0; turn < 12; turn += 1) await Promise.resolve();
}

afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) cleanup();
  for (const pending of deferred.splice(0)) pending.resolve(null);
  await flush();
});

function scope(): PluginWebBuildWorkspace {
  const id = `web-build-test-${++sequence}`;
  const path = `C:/fixture/${id}`;
  workspaceRuntimeRegistry.ensureWorkspace({ id, path, name: id }, "ready");
  const store = useBuildSystemsStore.getStore(id);
  cleanups.push(() => workspaceRuntimeRegistry.removeWorkspace(id));
  return { id, path, store };
}

function view(workspace: PluginWebBuildWorkspace, generation = 1): BuildView {
  return {
    workspaceRoot: workspace.path,
    generation,
    issues: [],
    instances: [
      {
        pluginID: PLUGIN,
        buildSystemID: "fixture",
        displayName: "Fixture",
        root: ".",
        markers: [],
        modelSource: "static",
        stale: false,
        syncDigest: "sync",
        optionFingerprint: `options-${generation}`,
        options: [],
      },
    ],
  };
}

function fixture() {
  let workspace: PluginWebBuildWorkspace | null = scope();
  let label = "main";
  let receive: ((request: PluginWebBuildRequest) => void) | null = null;
  let workspaceChanged: (() => void) | null = null;
  let pluginChanged: ((pluginId: string) => void) | null = null;
  let revision = 0;
  let blocked = false;
  let unlistened = 0;
  let revoked: ((id: string) => void) | null = null;
  const calls: Array<{ operationId: string; accept: boolean }> = [];
  const completions = new Map<
    string,
    { resolve: (value: BuildView | null) => void; reject: (error: unknown) => void }
  >();
  const timers = new Set<() => void>();
  const failures: unknown[] = [];
  const delivered: string[] = [];
  const port: PluginWebBuildPort = {
    windowLabel: () => label,
    workspace: () => workspace,
    listen: async (handler) => {
      receive = handler;
      return () => {
        receive = null;
        unlistened += 1;
      };
    },
    handle: async (operationId, accept) => {
      calls.push({ operationId, accept });
      if (!accept) return null;
      return new Promise<BuildView | null>((resolve, reject) => {
        completions.set(operationId, { resolve, reject });
        deferred.push({ resolve });
      });
    },
    complete: async (operationId) => {
      delivered.push(operationId);
    },
    listenRevoked: async (handler) => {
      revoked = handler;
      return () => {
        revoked = null;
      };
    },
    subscribeWorkspace: (handler) => {
      workspaceChanged = handler;
      return () => {
        workspaceChanged = null;
      };
    },
    subscribePlugin: (handler) => {
      pluginChanged = handler;
      return () => {
        pluginChanged = null;
      };
    },
    pluginGuard: () => {
      const captured = revision;
      return () => {
        if (blocked || revision !== captured) throw new Error("revoked fixture");
      };
    },
    scheduleDeadline: (handler) => {
      timers.add(handler);
      return () => {
        timers.delete(handler);
      };
    },
    report: (error) => {
      failures.push(error);
    },
  };
  const request = (overrides: Partial<PluginWebBuildRequest> = {}): PluginWebBuildRequest => ({
    operationId: `operation-${++sequence}`,
    pluginId: PLUGIN,
    pageLabel: "plugin-web-fixture",
    pageGeneration: 1,
    hostLabel: "main",
    workspaceId: workspace!.id,
    workspacePath: workspace!.path,
    method: "build.instances",
    ...overrides,
  });
  return {
    port,
    request,
    calls,
    completions,
    timers,
    failures,
    delivered,
    revoke: (id: string) => revoked?.(id),
    workspace: () => workspace!,
    emit: (payload: PluginWebBuildRequest) => receive?.(payload),
    switchWorkspace: (next: PluginWebBuildWorkspace | null) => {
      workspace = next;
      workspaceChanged?.();
    },
    windowLabel: (next: string) => {
      label = next;
      workspaceChanged?.();
    },
    pluginActive: (active: boolean, id = PLUGIN) => {
      blocked = !active;
      revision += 1;
      pluginChanged?.(id);
    },
    unlistened: () => unlistened,
    subscriptions: () => !!workspaceChanged || !!pluginChanged,
  };
}

async function start(f: ReturnType<typeof fixture>) {
  const cleanup = await initializePluginWebBuildListener(f.port);
  cleanups.push(cleanup);
  return cleanup;
}

test("instance reads accept only a native token and mirror the existing workspace store without advancing requests", async () => {
  const f = fixture();
  await start(f);
  const payload = f.request();
  f.emit(payload);
  expect(f.calls).toEqual([{ operationId: payload.operationId, accept: true }]);
  expect(f.workspace().store.getState().requestSequence).toBe(0);
  f.completions.get(payload.operationId)!.resolve(view(f.workspace()));
  await flush();
  expect(f.workspace().store.getState().generation).toBe(1);
  expect(f.delivered).toEqual([payload.operationId]);
  expect(f.timers.size).toBe(0);
});

test("all remaining contract methods enter the workflow port after native acceptance", async () => {
  for (const method of [
    "build.refresh",
    "build.runTask",
    "build.runTests",
    "build.dependencies",
    "build.cancel",
  ] as const) {
    const f = fixture();
    const received: string[] = [];
    f.port.workflow = async (request, workspace, signal) => {
      expect(workspace).toBe(f.workspace());
      expect(signal.aborted).toBe(false);
      received.push(request.method);
    };
    await start(f);
    const request = f.request({ method });
    f.emit(request);
    f.completions.get(request.operationId)!.resolve(null);
    await flush();
    expect(received).toEqual([method]);
    expect(f.delivered).toEqual([]);
  }
});

test("native navigation revocation aborts only its own page workflow", async () => {
  const f = fixture();
  const signals = new Map<string, AbortSignal>();
  const releases: Array<() => void> = [];
  f.port.workflow = (request, _workspace, signal) =>
    new Promise<void>((resolve) => {
      signals.set(request.operationId, signal);
      releases.push(resolve);
    });
  cleanups.push(() => releases.forEach((release) => release()));
  await start(f);
  const first = f.request({ method: "build.runTask", pageLabel: "page-a" });
  const second = f.request({ method: "build.runTask", pageLabel: "page-b" });
  f.emit(first);
  f.emit(second);
  f.completions.get(first.operationId)!.resolve(null);
  f.completions.get(second.operationId)!.resolve(null);
  await flush();
  f.revoke(first.operationId);
  expect(signals.get(first.operationId)!.aborted).toBe(true);
  expect(signals.get(second.operationId)!.aborted).toBe(false);
});

test("workspace switch during native workflow admission cannot show a late approval", async () => {
  const f = fixture();
  let entered = false;
  f.port.workflow = async () => {
    entered = true;
  };
  await start(f);
  const request = f.request({ method: "build.dependencies" });
  f.emit(request);
  f.switchWorkspace(scope());
  f.completions.get(request.operationId)!.resolve(null);
  await flush();
  expect(entered).toBe(false);
});

test("option edits share the existing store request barrier and apply native effective options", async () => {
  const f = fixture();
  await start(f);
  const updates: string[] = [];
  f.port.optionsChanged = async (workspace) => {
    expect(workspace.store.getState().generation).toBe(2);
    updates.push(workspace.id);
  };
  const payload = f.request({ method: "build.setOptions" });
  f.emit(payload);
  expect(f.workspace().store.getState().status).toBe("loading");
  const result = view(f.workspace(), 2);
  result.instances[0]!.options = [{ id: "offline", kind: "boolean", choices: [], value: true }];
  f.completions.get(payload.operationId)!.resolve(result);
  await flush();
  expect(f.workspace().store.getState().status).toBe("ready");
  expect(
    Object.values(f.workspace().store.getState().windows)[0]!.instances[0]!.options[0]!.value,
  ).toBe(true);
  expect(updates).toEqual([f.workspace().id]);
});

test("malformed and other-window events cannot invoke a build request", async () => {
  const f = fixture();
  await start(f);
  f.emit(f.request({ hostLabel: "workspace-other" }));
  f.emit(f.request({ pageGeneration: 0 }));
  f.emit(f.request({ method: "build.unknown" as PluginWebBuildRequest["method"] }));
  expect(f.calls).toEqual([]);
  const foreign = f.request({ workspaceId: "other", workspacePath: "C:/fixture/other" });
  f.emit(foreign);
  expect(f.calls).toEqual([{ operationId: foreign.operationId, accept: false }]);
});

test("repeated native event is accepted once and native failures release the request barrier", async () => {
  const f = fixture();
  await start(f);
  const payload = f.request({ method: "build.setOptions" });
  f.emit(payload);
  f.emit(payload);
  expect(f.calls.length).toBe(1);
  const failure = new Error("native request refused");
  f.completions.get(payload.operationId)!.reject(failure);
  await flush();
  expect(f.failures).toEqual([failure]);
  expect(f.workspace().store.getState().status).toBe("idle");
  expect(f.timers.size).toBe(0);
});

test("A to B to A invalidates pending work permanently and rejects a late view", async () => {
  const f = fixture();
  await start(f);
  const original = f.workspace();
  const payload = f.request({ method: "build.setOptions" });
  f.emit(payload);
  f.switchWorkspace(scope());
  f.switchWorkspace(original);
  expect(f.calls).toEqual([
    { operationId: payload.operationId, accept: true },
    { operationId: payload.operationId, accept: false },
  ]);
  f.completions.get(payload.operationId)!.resolve(view(original, 9));
  await flush();
  expect(original.store.getState().generation).toBeNull();
  expect(f.delivered).toEqual([]);
  expect(f.timers.size).toBe(0);
});

test("disable and re-enable never revive an old request or write its view", async () => {
  const f = fixture();
  await start(f);
  const payload = f.request();
  f.emit(payload);
  f.pluginActive(false);
  f.pluginActive(true);
  f.completions.get(payload.operationId)!.resolve(view(f.workspace(), 8));
  await flush();
  expect(f.workspace().store.getState().generation).toBeNull();
  expect(f.calls.filter((call) => !call.accept).length).toBe(1);
});

test("closed workspace and changed host label refuse in-flight requests", async () => {
  for (const change of ["workspace", "window"] as const) {
    const f = fixture();
    const cleanup = await start(f);
    const original = f.workspace();
    const payload = f.request();
    f.emit(payload);
    if (change === "workspace") f.switchWorkspace(null);
    else f.windowLabel("workspace-other");
    f.completions.get(payload.operationId)!.resolve(view(original, 3));
    await flush();
    expect(original.store.getState().generation).toBeNull();
    expect(f.calls[f.calls.length - 1]).toEqual({
      operationId: payload.operationId,
      accept: false,
    });
    cleanup();
  }
});

test("manual deadline cancels accepted native work and ignores the late answer", async () => {
  const f = fixture();
  await start(f);
  const payload = f.request({ method: "build.setOptions" });
  f.emit(payload);
  for (const timer of [...f.timers]) timer();
  expect(f.timers.size).toBe(0);
  expect(f.calls[f.calls.length - 1]).toEqual({ operationId: payload.operationId, accept: false });
  f.completions.get(payload.operationId)!.resolve(view(f.workspace(), 10));
  await flush();
  expect(f.workspace().store.getState().generation).toBeNull();
});

test("cleanup removes listeners subscriptions deadlines and refuses pending work once", async () => {
  const f = fixture();
  const cleanup = await start(f);
  const payload = f.request();
  f.emit(payload);
  cleanup();
  cleanup();
  expect(f.unlistened()).toBe(1);
  expect(f.subscriptions()).toBe(false);
  expect(f.timers.size).toBe(0);
  expect(f.calls.filter((call) => !call.accept).length).toBe(1);
  f.completions.get(payload.operationId)!.resolve(view(f.workspace()));
  await flush();
  expect(f.workspace().store.getState().generation).toBeNull();
});

test("failed listener acquisition releases both lifecycle subscriptions", async () => {
  const f = fixture();
  const failure = new Error("listen failed");
  f.port.listen = async () => {
    throw failure;
  };
  await expect(initializePluginWebBuildListener(f.port)).rejects.toBe(failure);
  expect(f.subscriptions()).toBe(false);
  expect(f.timers.size).toBe(0);
});

test("a passive read cannot overwrite a newer host edit or a different native workspace", async () => {
  const f = fixture();
  await start(f);
  const first = f.request();
  f.emit(first);
  const edit = f.request({ method: "build.setOptions" });
  f.emit(edit);
  f.completions.get(edit.operationId)!.resolve(view(f.workspace(), 4));
  await flush();
  f.completions.get(first.operationId)!.resolve(view(f.workspace(), 3));
  await flush();
  expect(f.workspace().store.getState().generation).toBe(4);
  const wrong = f.request();
  f.emit(wrong);
  f.completions
    .get(wrong.operationId)!
    .resolve({ ...view(f.workspace(), 5), workspaceRoot: "C:/fixture/other" });
  await flush();
  expect(f.workspace().store.getState().generation).toBe(4);
});

test("production adapter subscribes to this window and invokes only the native pending-request command", async () => {
  const workspace = scope();
  const prior = workspaceRuntimeRegistry.getActiveWorkspace();
  workspaceRuntimeRegistry.activateWorkspace(
    { id: workspace.id, path: workspace.path, name: workspace.id },
    "ready",
  );
  let receive!: (event: { payload: PluginWebBuildRequest }) => void;
  let released = false;
  const windowSpy = spyOn(windows, "getCurrentWindow").mockReturnValue({
    label: "main",
  } as ReturnType<typeof windows.getCurrentWindow>);
  const listenSpy = spyOn(events, "listen").mockImplementation(async (_name, handler) => {
    receive = handler as typeof receive;
    return () => {
      released = true;
    };
  });
  const invokeSpy = spyOn(native, "invoke").mockResolvedValue(view(workspace));
  let cleanup: (() => void) | undefined;
  try {
    cleanup = await initializePluginWebBuildListener();
    expect(listenSpy).toHaveBeenCalledWith("plugin-web-build-request", expect.any(Function), {
      target: { kind: "Window", label: "main" },
    });
    receive({
      payload: {
        operationId: "native-token",
        pluginId: PLUGIN,
        pageLabel: "plugin-web-fixture",
        pageGeneration: 1,
        hostLabel: "main",
        workspaceId: workspace.id,
        workspacePath: workspace.path,
        method: "build.instances",
      },
    });
    await flush();
    expect(invokeSpy).toHaveBeenNthCalledWith(1, "declarative_plugins_web_build_handle", {
      operationId: "native-token",
      phase: "accept",
    });
    expect(invokeSpy).toHaveBeenNthCalledWith(2, "declarative_plugins_web_build_handle", {
      operationId: "native-token",
      phase: "complete",
    });
    expect(invokeSpy).toHaveBeenCalledTimes(2);
  } finally {
    cleanup?.();
    expect(released).toBe(true);
    listenSpy.mockRestore();
    invokeSpy.mockRestore();
    windowSpy.mockRestore();
    if (prior) workspaceRuntimeRegistry.activateWorkspace(prior.descriptor, prior.status);
  }
});
