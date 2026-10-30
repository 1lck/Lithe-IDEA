import { afterEach, expect, mock, test } from "bun:test";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { useBuildSystemsStore } from "./build-systems-store";
import type { BuildView } from "./build-systems-types";
import type { BuildDependenciesNative } from "./build-dependencies-native";
import type { BuildDependenciesResult, BuildDependenciesReview } from "./build-dependencies-types";
import { BuildDependenciesSession } from "./build-dependencies-session";
import type { BuildOutputEvent } from "./output/build-output-types";
import { useBuildOutputStore } from "./output/build-output-store";
import * as lspAdapter from "@/platform/lsp-core-adapter";

const sharedLanguageStart = mock(
  async (_args: unknown, _signal?: AbortSignal): Promise<void> => {},
);
mock.module("@/platform/lsp-core-adapter", () => ({
  ...lspAdapter,
  ensureBuildProviderLanguageSession: sharedLanguageStart,
}));
mock.module("@/platform/tauri-core", () => ({ invoke: mock(async () => undefined) }));

const ROOT = "D:/fixture/dependencies";
const PLUGIN = "dev.lithe.fixture.dependencies";
const pending: Array<() => void> = [];
const releases: Array<() => void> = [];
const work: Promise<void>[] = [];
function deferred<T>(fallback: T) {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((yes, no) => {
    resolve = yes;
    reject = no;
  });
  pending.push(() => resolve(fallback));
  return { promise, resolve, reject };
}
async function flush() {
  for (let index = 0; index < 32; index++) await Promise.resolve();
}
afterEach(async () => {
  releases
    .splice(0)
    .reverse()
    .forEach((release) => release());
  pending.splice(0).forEach((finish) => finish());
  await Promise.allSettled(work.splice(0));
  await flush();
  workspaceRuntimeRegistry.resetForTests();
  sharedLanguageStart.mockReset().mockImplementation(async () => {});
});
function fixture() {
  workspaceRuntimeRegistry.activateWorkspace(
    { id: "dependencies-tests", name: "Fixture", path: ROOT },
    "ready",
  );
  const store = useBuildSystemsStore.getStore("dependencies-tests");
  store.getState().actions.reset();
  const view: BuildView = {
    generation: 9,
    workspaceRoot: ROOT,
    issues: [],
    instances: [
      {
        pluginID: PLUGIN,
        buildSystemID: "fixture",
        root: "reactor",
        displayName: "Fixture",
        markers: [],
        modelSource: "hostIntegration",
        model: { projects: [{ id: "app", name: "App", path: "reactor/app" }] },
        options: [],
        stale: false,
        syncDigest: "sync",
        optionFingerprint: "options",
      },
    ],
  };
  store.getState().actions.applyView(view, store.getState().actions.beginRequest());
  const output = useBuildOutputStore.getStore("dependencies-tests");
  output.getState().actions.reset();
  const review: BuildDependenciesReview = {
    operationId: "dependencies-1",
    pluginId: PLUGIN,
    buildSystemId: "fixture",
    root: "reactor",
    workspaceRoot: ROOT,
    generation: 9,
    executesProjectCode: true,
    mayUseNetwork: true,
    kind: "dependencies",
    projectId: "app",
    title: "Fixture",
  };
  const cancelled: BuildDependenciesResult = {
    ...review,
    terminal: { kind: "cancelled" },
    dependencies: null,
  };
  const result = deferred<BuildDependenciesResult>(cancelled);
  const order: string[] = [];
  const sinks: Array<(event: BuildOutputEvent) => void> = [];
  const unlisten = mock(() => {});
  const native: BuildDependenciesNative = {
    windowLabel: () => "workspace-dependencies",
    save: mock(async () => {
      order.push("save");
    }),
    sync: mock(async () => {
      order.push("sync");
      const actions = store.getState().actions;
      actions.applyView(view, actions.beginRequest());
    }),
    definition: mock(async () => ({
      tasks: [],
      programs: [{ kind: "buildSystem", buildSystemID: "fixture" }],
      dependencies: { source: "hostIntegration" as const },
    })),
    prepare: mock(async () => {
      order.push("prepare");
      return review;
    }),
    execute: mock(async () => {
      order.push("execute");
      const value = await result.promise;
      sinks[sinks.length - 1]?.({ ...review, type: "terminal", terminal: value.terminal });
      return value;
    }),
    cancel: mock(async () => {
      order.push("cancel");
    }),
    listen: mock(async (_window, sink) => {
      order.push("listen");
      sinks.push(sink);
      return unlisten;
    }),
  };
  const session = new BuildDependenciesSession(
    "dependencies-tests",
    PLUGIN,
    "fixture",
    "reactor",
    store,
    native,
  );
  const release = session.attach();
  releases.push(release);
  const start = () => {
    const operation = session.start("app");
    work.push(operation);
    return operation;
  };
  const success: BuildDependenciesResult = {
    ...review,
    terminal: { kind: "succeeded", exitCode: 0 },
    dependencies: [
      {
        name: "library",
        version: "2",
        properties: { selectedVersion: "2" },
        children: [{ name: "transitive", children: [] }],
      },
    ],
  };
  return {
    session,
    store,
    view,
    output,
    review,
    native,
    result,
    sinks,
    order,
    unlisten,
    release,
    start,
    success,
  };
}

test("prepare follows save/sync and explicit approval; Core tree publishes after completion", async () => {
  const f = fixture();
  expect(f.order).toEqual([]);
  const operation = f.start();
  await flush();
  expect(f.order).toEqual(["save", "sync", "prepare"]);
  expect(f.session.getSnapshot().review).toEqual(f.review);
  expect(f.native.execute).not.toHaveBeenCalled();
  f.session.decide(true);
  await flush();
  expect(f.order.indexOf("listen")).toBeLessThan(f.order.indexOf("execute"));
  expect(f.session.getSnapshot().dependencies).toBeNull();
  f.result.resolve(f.success);
  await operation;
  expect(f.session.getSnapshot().dependencies).toEqual(f.success.dependencies);
  expect(f.session.getSnapshot().projectId).toBe("app");
  expect(f.unlisten).toHaveBeenCalledTimes(1);
});
test("declined approval cancels the native review without invoking dependency command", async () => {
  const f = fixture();
  const operation = f.start();
  await flush();
  f.session.decide(false);
  await operation;
  expect(f.native.cancel).toHaveBeenCalledWith(f.review.operationId);
  expect(f.native.execute).not.toHaveBeenCalled();
  expect(f.session.getSnapshot().dependencies).toBeNull();
});
test("same native busy barrier covers dependency consent, and duplicate starts do not prepare twice", async () => {
  const f = fixture();
  const operation = f.start();
  await flush();
  expect(f.store.getState().status).toBe("loading");
  await f.session.start("app");
  expect(f.native.prepare).toHaveBeenCalledTimes(1);
  f.session.decide(false);
  await operation;
  expect(f.store.getState().status).toBe("ready");
});
test("dependency Stop retries shared language cleanup after its initialization promise has rejected", async () => {
  const f = fixture();
  f.review.provider = {
    token: 7,
    context: {
      window: "workspace-dependencies",
      workspaceRoot: ROOT,
      generation: 9,
      pluginId: PLUGIN,
      packageIdentity: "fixture:digest",
      buildSystem: "fixture",
      instanceRoot: "reactor",
      instanceDirectory: `${ROOT}/reactor`,
    },
    executesProjectCode: true,
    mayUseNetwork: true,
    launchPlan: { buildProvider: { languageServer: "fixture-language" } },
    program: {
      pluginId: PLUGIN,
      languageId: "fixture-language",
      serverPath: "fixture.exe",
      serverArgs: [],
      environment: {},
    },
  };
  const shared = deferred<void>(undefined);
  const retry = deferred<void>(undefined);
  const retryCleanup = mock(async () => {
    await retry.promise;
  });
  sharedLanguageStart.mockImplementation(async () => {
    await shared.promise;
  });
  const operation = f.start();
  await flush();
  f.session.decide(true);
  await flush();
  expect(sharedLanguageStart).toHaveBeenCalledTimes(1);
  const stopping = f.session.cancel().catch((error: unknown) => error);
  shared.reject(Object.assign(new Error("plugin.build.cleanupFailed"), { retryCleanup }));
  expect(String(await stopping)).toContain("plugin.build.cleanupFailed");
  await operation;
  expect(f.session.getSnapshot().phase).toBe("cancelFailed");
  expect(f.native.execute).not.toHaveBeenCalled();
  let finished = false;
  const stopped = f.session.cancel().then(() => {
    finished = true;
  });
  work.push(stopped);
  await flush();
  expect(f.native.cancel).toHaveBeenCalledTimes(2);
  expect(retryCleanup).toHaveBeenCalledTimes(1);
  expect(finished).toBe(false);
  retry.resolve(undefined);
  await stopped;
  expect(f.session.getSnapshot().phase).toBe("ended");
  expect(f.session.getSnapshot().dependencies).toBeNull();
});

test("cleanup failure keeps Stop retryable and never publishes a tree", async () => {
  const f = fixture();
  f.native.execute = mock(async () => {
    throw new Error("plugin.build.cleanupFailed");
  });
  const operation = f.start();
  await flush();
  f.session.decide(true);
  await operation;
  expect(f.session.getSnapshot().phase).toBe("cancelFailed");
  expect(f.session.getSnapshot().dependencies).toBeNull();
  expect(f.store.getState().status).toBe("loading");
  await f.session.start("app");
  expect(f.native.prepare).toHaveBeenCalledTimes(1);
  await f.session.cancel();
  expect(f.session.getSnapshot().phase).toBe("ended");
});
for (const change of ["package", "configuration", "workspace", "window"] as const) {
  test(`${change} invalidation rejects a late tree without waiting for a closed listener`, async () => {
    const f = fixture();
    const operation = f.start();
    await flush();
    f.session.decide(true);
    await flush();
    const drain = mock(() => {
      throw new Error("cancelled listeners cannot drain");
    });
    f.native.scheduleOutputDrain = drain;
    if (change === "package") f.store.getState().actions.dropPlugin(PLUGIN);
    else if (change === "configuration") {
      const next = structuredClone(f.view);
      next.instances[0]!.optionFingerprint = "changed";
      f.store.getState().actions.applyView(next, f.store.getState().actions.beginRequest());
    } else if (change === "workspace")
      workspaceRuntimeRegistry.activateWorkspace(
        { id: "other", path: "D:/other", name: "Other" },
        "ready",
      );
    else f.release();
    f.result.resolve(f.success);
    await operation;
    expect(f.session.getSnapshot().dependencies).toBeNull();
    expect(drain).not.toHaveBeenCalled();
    f.release();
    workspaceRuntimeRegistry.resetForTests();
  });
}
test("late review after disposal is cancelled even when acquisition could not be aborted", async () => {
  const f = fixture();
  const review = deferred(f.review);
  f.native.prepare = mock(async () => review.promise);
  const operation = f.start();
  await flush();
  f.release();
  review.resolve(f.review);
  await operation;
  expect(f.native.cancel).toHaveBeenCalledWith(f.review.operationId);
  expect(f.native.execute).not.toHaveBeenCalled();
});
test("published trees become stale after model generation change", async () => {
  const f = fixture();
  const operation = f.start();
  await flush();
  f.session.decide(true);
  await flush();
  f.result.resolve(f.success);
  await operation;
  expect(f.session.getSnapshot().stale).toBe(false);
  const next = structuredClone(f.view);
  next.generation++;
  f.store.getState().actions.applyView(next, f.store.getState().actions.beginRequest());
  expect(f.session.getSnapshot().stale).toBe(true);
});
test("wrong project result and events for another operation cannot publish", async () => {
  const f = fixture();
  const operation = f.start();
  await flush();
  f.session.decide(true);
  await flush();
  f.sinks[f.sinks.length - 1]!({
    ...f.review,
    operationId: "older",
    type: "chunk",
    stream: "stdout",
    text: "stale data",
  });
  f.result.resolve({ ...f.success, projectId: "different" });
  await operation;
  expect(f.session.getSnapshot().dependencies).toBeNull();
  expect(f.session.getSnapshot().phase).toBe("failed");
  expect(f.output.getState().sessions[f.session.run.sessionId]?.lines).toEqual([]);
  await f.session.cancel();
});
test("invalid review retains the native owner if cancelling that review fails", async () => {
  const f = fixture();
  f.native.prepare = mock(async () => ({ ...f.review, projectId: "wrong-project" }));
  f.native.cancel = mock(async () => {
    throw new Error("plugin.build.cleanupFailed");
  });
  await f.start();
  expect(f.native.execute).not.toHaveBeenCalled();
  expect(f.session.getSnapshot().phase).toBe("cancelFailed");
  expect(f.store.getState().status).toBe("loading");
  await f.session.start("app");
  expect(f.native.prepare).toHaveBeenCalledTimes(1);
  f.native.cancel = mock(async () => {});
  await f.session.cancel();
  expect(f.session.getSnapshot().phase).toBe("ended");
});
