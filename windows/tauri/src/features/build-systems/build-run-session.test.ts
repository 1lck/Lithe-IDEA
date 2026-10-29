import { afterEach, expect, mock, test } from "bun:test";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { buildSystemViewId, useBuildSystemsStore } from "./build-systems-store";
import type { BuildView } from "./build-systems-types";
import type { BuildRunNative } from "./build-run-native";
import type { BuildRunReview, BuildRunSelection } from "./build-run-types";
import { BuildRunSession, OUTPUT_DRAIN_TIMEOUT_MS } from "./build-run-session";
import { useBuildOutputStore } from "./output/build-output-store";
import type {
  BuildOperationIdentity,
  BuildOutputEvent,
  BuildRunTerminal,
} from "./output/build-output-types";

const ROOT = "D:/fixture/run-workspace";
const PLUGIN = "dev.lithe.fixture.tasks";
const VIEW = buildSystemViewId(PLUGIN, "fixture");
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
  for (let index = 0; index < 24; index++) await Promise.resolve();
}
afterEach(async () => {
  releases
    .splice(0)
    .reverse()
    .forEach((release) => release());
  pending.splice(0).forEach((resolve) => resolve());
  await Promise.allSettled(work.splice(0));
  await flush();
  workspaceRuntimeRegistry.resetForTests();
});
function view(): BuildView {
  return {
    generation: 7,
    workspaceRoot: ROOT,
    issues: [],
    instances: [
      {
        pluginID: PLUGIN,
        buildSystemID: "fixture",
        root: ".",
        displayName: "Fixture",
        markers: [],
        modelSource: "command",
        model: { projects: [{ id: "project", name: "App", path: "." }] },
        options: [],
        stale: false,
        syncDigest: "sync",
        optionFingerprint: "options",
      },
    ],
  };
}
const selection: BuildRunSelection = {
  kind: "task",
  taskId: "build",
  projectId: "project",
  targetId: null,
  modelTaskId: null,
  suite: null,
  case: null,
  userArguments: ["--flag with spaces"],
};
function fixture() {
  workspaceRuntimeRegistry.activateWorkspace(
    { id: "run-tests", name: "Fixture", path: ROOT },
    "ready",
  );
  const store = useBuildSystemsStore.getStore("run-tests");
  store.getState().actions.reset();
  const initial = view();
  initial.instances.push({ ...initial.instances[0]!, root: "nested" });
  store.getState().actions.applyView(initial, store.getState().actions.beginRequest());
  const output = useBuildOutputStore.getStore("run-tests");
  output.getState().actions.reset();
  const review: BuildRunReview = {
    operationId: "native-run-1",
    pluginId: PLUGIN,
    buildSystemId: "fixture",
    workspaceRoot: ROOT,
    root: ".",
    generation: 7,
    executesProjectCode: true,
    mayUseNetwork: true,
    kind: "task",
    title: "Build fixture",
  };
  const terminal = deferred<BuildRunTerminal>({ kind: "cancelled" });
  const order: string[] = [];
  const sinks: Array<(event: BuildOutputEvent) => void> = [];
  const unlisten = mock(() => {});
  const native: BuildRunNative = {
    windowLabel: () => "workspace-fixture",
    definition: mock(async (): Promise<import("./build-run-types").BuildRunDefinition> => {
      order.push("definition");
      return {
        tasks: [{ id: "build", displayName: "Build", scopes: ["project"] }],
        programs: [
          {
            kind: "buildSystem",
            buildSystemID: "fixture",
            invocation: { executables: [{ kind: "command", command: "fixture-tool" }] },
          },
        ],
      };
    }),
    save: mock(async () => {
      order.push("save");
    }),
    sync: mock(async () => {
      order.push("sync");
      const actions = store.getState().actions;
      actions.applyView(initial, actions.beginRequest());
    }),
    prepare: mock(async () => {
      order.push("prepare");
      return review;
    }),
    execute: mock(async () => {
      order.push("execute");
      const result = await terminal.promise;
      sinks[sinks.length - 1]?.({ ...review, type: "terminal", terminal: result });
      return result;
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
  const session = new BuildRunSession("run-tests", PLUGIN, "fixture", ".", store, native);
  const release = session.attach();
  releases.push(release);
  const start = () => {
    const result = session.start(selection);
    work.push(result);
    return result;
  };
  const identity: BuildOperationIdentity = { ...review, title: review.title };
  const send = (
    event: Omit<BuildOutputEvent, keyof BuildOperationIdentity> & Partial<BuildOutputEvent>,
  ) => sinks[sinks.length - 1]!({ ...identity, ...event } as BuildOutputEvent);
  const state = () => output.getState().sessions[session.sessionId];
  return {
    session,
    store,
    output,
    native,
    review,
    terminal,
    order,
    sinks,
    unlisten,
    release,
    start,
    identity,
    send,
    state,
  };
}

test("save, sync and native prepare are ordered; neither opening nor review executes a command", async () => {
  const f = fixture();
  expect(f.order).toEqual([]);
  const operation = f.start();
  await flush();
  expect(f.order).toEqual(["save", "sync", "definition", "prepare"]);
  expect(f.session.getSnapshot().review).toEqual(f.review);
  expect(f.native.prepare).toHaveBeenCalledWith(ROOT, PLUGIN, "fixture", ".", selection);
  expect(f.native.execute).toHaveBeenCalledTimes(0);
  f.session.decide(false);
  await operation;
  expect(f.native.cancel).toHaveBeenCalledWith(f.review.operationId);
  expect(f.native.execute).toHaveBeenCalledTimes(0);
});
test("the existing build busy barrier spans consent and execution so queued file sync cannot invalidate its own launch", async () => {
  const f = fixture();
  const operation = f.start();
  await flush();
  expect(f.store.getState().status).toBe("loading");
  f.session.decide(true);
  await flush();
  expect(f.store.getState().status).toBe("loading");
  f.terminal.resolve({ kind: "succeeded", exitCode: 0 });
  await operation;
  expect(f.store.getState().status).toBe("ready");
});
test("listener acquisition completes before execute, including synchronous output and a fast terminal", async () => {
  const f = fixture();
  const acquisition = deferred<() => void>(f.unlisten);
  f.native.listen = mock(async (_label, sink) => {
    f.sinks.push(sink);
    f.order.push("listen");
    return acquisition.promise;
  });
  f.native.execute = mock(async (): Promise<BuildRunTerminal> => {
    f.send({ type: "chunk", stream: "stdout", text: "first output\n" });
    f.send({ type: "chunk", stream: "stderr", text: "warning\n" });
    f.send({ type: "terminal", terminal: { kind: "succeeded", exitCode: 0 } });
    return { kind: "succeeded", exitCode: 0 };
  });
  const operation = f.start();
  await flush();
  f.session.decide(true);
  await flush();
  expect(f.native.execute).toHaveBeenCalledTimes(0);
  acquisition.resolve(f.unlisten);
  await operation;
  expect(f.native.listen).toHaveBeenCalledWith("workspace-fixture", expect.any(Function));
  expect(f.state()!.lines.map((row) => [row.stream, row.text])).toEqual([
    ["stdout", "first output"],
    ["stderr", "warning"],
  ]);
  expect(f.state()!.status).toBe("succeeded");
  expect(f.unlisten).toHaveBeenCalledTimes(1);
});
test("cancel failure keeps the same native owner; retry waits for the native terminal result", async () => {
  const f = fixture();
  const operation = f.start();
  await flush();
  f.session.decide(true);
  await flush();
  f.native.cancel = mock(async () => {
    throw new Error("fixture cleanup failure");
  });
  await expect(f.session.cancel()).rejects.toThrow("fixture cleanup failure");
  expect(f.state()!.status).toBe("running");
  expect(f.session.getSnapshot().phase).toBe("cancelFailed");
  expect(f.store.getState().status).toBe("loading");
  await f.session.start(selection);
  expect(f.native.execute).toHaveBeenCalledTimes(1);
  const confirmation = deferred<void>(undefined);
  f.native.cancel = mock(() => confirmation.promise);
  const retry = f.session.cancel();
  await flush();
  expect(f.session.getSnapshot().phase).toBe("stopping");
  confirmation.resolve();
  await retry;
  expect(f.state()!.status).toBe("running");
  f.terminal.resolve({ kind: "cancelled", exitCode: null });
  await operation;
  expect(f.state()!.status).toBe("cancelled");
  expect(f.store.getState().status).toBe("ready");
  expect(f.native.cancel).toHaveBeenCalledWith(f.review.operationId);
});
test("a fast invoke result does not truncate queued chunks or decoded diagnostics before the terminal event", async () => {
  const f = fixture();
  let timeout: (() => void) | undefined;
  const cancelTimer = mock(() => {
    timeout = undefined;
  });
  f.native.scheduleOutputDrain = (callback, milliseconds) => {
    expect(milliseconds).toBe(OUTPUT_DRAIN_TIMEOUT_MS);
    timeout = callback;
    return cancelTimer;
  };
  f.native.execute = mock(
    async (): Promise<BuildRunTerminal> => ({ kind: "succeeded", exitCode: 0 }),
  );
  const operation = f.start();
  await flush();
  f.session.decide(true);
  await flush();
  expect(f.state()!.status).toBe("running");
  expect(timeout).toBeDefined();
  f.send({ type: "chunk", stream: "stdout", text: "queued after invoke\n" });
  f.send({
    type: "diagnostics",
    diagnostics: [{ path: "app.ts", line: 2, severity: "warning", message: "queued diagnostic" }],
  });
  f.send({ type: "terminal", terminal: { kind: "succeeded", exitCode: 0 } });
  await operation;
  expect(f.state()!.lines[0]!.text).toBe("queued after invoke");
  expect(f.state()!.diagnostics[0]!.message).toBe("queued diagnostic");
  expect(cancelTimer).toHaveBeenCalledTimes(1);
  expect(timeout).toBeUndefined();
});
test("missing terminal delivery uses the real invoke result after a bounded drain and reports missing output", async () => {
  const f = fixture();
  let expire: (() => void) | undefined;
  const cancelTimer = mock(() => {
    expire = undefined;
  });
  f.native.scheduleOutputDrain = (callback) => {
    expire = callback;
    return cancelTimer;
  };
  f.native.execute = mock(async (): Promise<BuildRunTerminal> => ({ kind: "failed", exitCode: 2 }));
  const operation = f.start();
  await flush();
  f.session.decide(true);
  await flush();
  expect(f.state()!.status).toBe("running");
  expire!();
  await operation;
  expect(f.state()!.status).toBe("failed");
  expect(f.state()!.terminal!.exitCode).toBe(2);
  expect(f.state()!.subscriptionError).toContain("outputUnavailable");
  expect(cancelTimer).toHaveBeenCalledTimes(1);
});
test("actual native completion releases a failed Stop owner and a late cancellation error cannot affect the next review", async () => {
  const f = fixture();
  const operation = f.start();
  await flush();
  f.session.decide(true);
  await flush();
  const cancellation = deferred<void>(undefined);
  f.native.cancel = mock(() => cancellation.promise);
  const stop = f.session.cancel().catch((error) => error);
  await flush();
  f.terminal.resolve({ kind: "succeeded", exitCode: 0 });
  await operation;
  expect(f.state()!.status).toBe("succeeded");
  f.review.operationId = "native-run-2";
  const next = f.start();
  await flush();
  expect(f.session.getSnapshot().phase).toBe("review");
  cancellation.reject(new Error("old cancellation error"));
  await stop;
  expect(f.session.getSnapshot().phase).toBe("review");
  expect(f.session.getSnapshot().error).toBeNull();
  f.native.cancel = mock(async () => {});
  f.session.decide(false);
  await next;
});
test("late cancellation success cannot close a replacement operation's event subscription", async () => {
  const f = fixture();
  const operation = f.start();
  await flush();
  f.session.decide(true);
  await flush();
  const cancellation = deferred<void>(undefined);
  f.native.cancel = mock(() => cancellation.promise);
  const stop = f.session.cancel();
  await flush();
  f.terminal.resolve({ kind: "succeeded", exitCode: 0 });
  await operation;
  f.review.operationId = "native-run-2";
  const nextTerminal = deferred<BuildRunTerminal>({ kind: "cancelled" });
  f.native.execute = mock(async () => {
    const terminal = await nextTerminal.promise;
    f.sinks[f.sinks.length - 1]!({ ...f.review, type: "terminal", terminal });
    return terminal;
  });
  const next = f.start();
  await flush();
  f.session.decide(true);
  await flush();
  const releasedBefore = f.unlisten.mock.calls.length;
  cancellation.resolve();
  await stop;
  expect(f.unlisten.mock.calls.length).toBe(releasedBefore);
  expect(f.session.getSnapshot().phase).toBe("running");
  f.sinks[f.sinks.length - 1]!({
    ...f.review,
    type: "chunk",
    stream: "stdout",
    text: "replacement output\n",
  });
  expect(f.state()!.lines[0]!.text).toBe("replacement output");
  nextTerminal.resolve({ kind: "cancelled" });
  await next;
});
test("execute rejection cannot invent a terminal or discard the retryable owner", async () => {
  const f = fixture();
  const operation = f.start();
  await flush();
  f.session.decide(true);
  await flush();
  f.terminal.reject(new Error("plugin.build.cleanupFailed"));
  await operation;
  expect(f.state()!.status).toBe("running");
  expect(f.session.getSnapshot().phase).toBe("cancelFailed");
  expect(f.session.getSnapshot().error).toContain("cleanupFailed");
  await f.session.start(selection);
  expect(f.native.prepare).toHaveBeenCalledTimes(1);
});
test("a late authoritative terminal releases the retained owner after an execute rejection", async () => {
  const f = fixture();
  const operation = f.start();
  await flush();
  f.session.decide(true);
  await flush();
  f.terminal.reject(new Error("plugin.build.cleanupFailed"));
  await operation;
  expect(f.session.getSnapshot().phase).toBe("cancelFailed");
  f.send({ type: "terminal", terminal: { kind: "cancelled" } });
  expect(f.state()!.status).toBe("cancelled");
  expect(f.session.getSnapshot().phase).toBe("ended");
  expect(f.unlisten).toHaveBeenCalledTimes(1);
});
test("native cleanup confirmation can release an execute rejection without inventing an early terminal", async () => {
  const f = fixture();
  const operation = f.start();
  await flush();
  f.session.decide(true);
  await flush();
  f.terminal.reject(new Error("plugin.build.cleanupFailed"));
  await operation;
  const gate = deferred<void>(undefined);
  f.native.cancel = mock(() => gate.promise);
  const stop = f.session.cancel();
  await flush();
  expect(f.state()!.status).toBe("running");
  gate.resolve();
  await stop;
  expect(f.state()!.status).toBe("cancelled");
  expect(f.session.getSnapshot().phase).toBe("ended");
});
test("a review cancellation failure is retained without an automatic second cancellation", async () => {
  const f = fixture();
  const operation = f.start();
  await flush();
  f.native.cancel = mock(async () => {
    throw new Error("fixture review cleanup failed");
  });
  await expect(f.session.cancel()).rejects.toThrow("fixture review cleanup failed");
  await operation;
  expect(f.native.cancel).toHaveBeenCalledTimes(1);
  expect(f.session.getSnapshot().phase).toBe("cancelFailed");
  expect(f.native.execute).toHaveBeenCalledTimes(0);
  f.native.cancel = mock(async () => {});
  await f.session.cancel();
  expect(f.session.getSnapshot().phase).toBe("ended");
});
test("panel reopening preserves a failed Stop handle and receives the same operation's remaining events", async () => {
  const f = fixture();
  const operation = f.start();
  await flush();
  f.session.decide(true);
  await flush();
  const staleSink = f.sinks[0]!;
  f.native.cancel = mock(async () => {
    throw new Error("fixture stop failed while closed");
  });
  f.release();
  await flush();
  expect(f.unlisten).toHaveBeenCalledTimes(1);
  expect(f.session.getSnapshot().phase).toBe("cancelFailed");
  releases.push(f.session.attach());
  await flush();
  staleSink({ ...f.identity, type: "chunk", stream: "stdout", text: "closed callback" });
  f.send({ type: "chunk", stream: "stdout", text: "reopened\n" });
  expect(f.state()!.lines.map((row) => row.text)).toEqual(["reopened"]);
  f.native.cancel = mock(async () => {});
  await f.session.cancel();
  f.terminal.resolve({ kind: "cancelled" });
  await operation;
  expect(f.state()!.status).toBe("cancelled");
});
for (const key of [
  "operationId",
  "pluginId",
  "buildSystemId",
  "workspaceRoot",
  "root",
  "generation",
] as const) {
  test(`foreign ${key} events cannot enter the output store`, async () => {
    const f = fixture();
    const operation = f.start();
    await flush();
    f.session.decide(true);
    await flush();
    const wrong = {
      ...f.identity,
      [key]: key === "generation" ? 8 : "foreign",
      type: "chunk",
      stream: "stdout",
      text: "wrong",
    };
    f.sinks[0]!(wrong as BuildOutputEvent);
    expect(f.state()!.lines).toEqual([]);
    f.send({
      type: "diagnostics",
      diagnostics: [
        {
          path: "src/main.ts",
          line: 3,
          column: 2,
          severity: "error",
          message: "fixture diagnostic",
        },
      ],
    });
    f.send({
      type: "testResults",
      results: {
        tests: [
          {
            suite: "suite",
            case: "failed",
            status: "failed",
            invocations: 1,
            path: "src/main.ts",
            line: 3,
          },
        ],
        summary: { total: 1, passed: 0, failed: 1, errors: 0, skipped: 0 },
        success: false,
      },
    });
    f.terminal.resolve({ kind: "failed", exitCode: 1 });
    await operation;
    expect(f.state()!.diagnostics[0]!.message).toBe("fixture diagnostic");
    expect(f.state()!.testResults!.summary.failed).toBe(1);
  });
}
test("malformed native payloads cannot crash ingestion or manufacture success", async () => {
  const f = fixture();
  const operation = f.start();
  await flush();
  f.session.decide(true);
  await flush();
  for (const payload of [
    { type: "diagnostics", diagnostics: [{ path: null, message: "bad", line: 1 }] },
    { type: "testResults", results: { tests: [{ suite: null }], summary: {}, success: false } },
    { type: "terminal", terminal: { kind: "succeeded", message: {} } },
    { type: "chunk", stream: "stdout", text: 12 },
  ])
    f.sinks[0]!({ ...f.identity, ...payload } as unknown as BuildOutputEvent);
  expect(f.state()!.status).toBe("running");
  expect(f.state()!.diagnostics).toEqual([]);
  expect(f.state()!.testResults).toBeNull();
  f.terminal.resolve({ kind: "succeeded", exitCode: 0 });
  await operation;
});
for (const change of [
  "workspace",
  "generation",
  "selection",
  "disable",
  "reload",
  "window",
  "unmount",
] as const) {
  test(`${change} invalidates open consent before a stale approval can execute`, async () => {
    const f = fixture();
    const operation = f.start();
    await flush();
    if (change === "workspace")
      workspaceRuntimeRegistry.activateWorkspace(
        { id: "other", name: "Other", path: "D:/fixture/other" },
        "ready",
      );
    if (change === "generation") f.store.setState({ generation: 8 });
    if (change === "selection") f.store.getState().actions.selectInstance(VIEW, "nested");
    if (change === "disable") f.store.getState().actions.dropPlugin(PLUGIN);
    if (change === "reload") f.store.getState().actions.beginRequest();
    if (change === "window") {
      f.native.windowLabel = () => "workspace-other";
      f.store.setState({});
    }
    if (change === "unmount") f.release();
    f.session.decide(true);
    await operation;
    expect(f.native.execute).toHaveBeenCalledTimes(0);
    expect(f.native.cancel).toHaveBeenCalledWith(f.review.operationId);
  });
}
test("unmount before a late prepare cancels the newly returned native slot without opening approval", async () => {
  const f = fixture();
  const gate = deferred(f.review);
  f.native.prepare = mock(() => gate.promise);
  const operation = f.start();
  await flush();
  f.release();
  gate.resolve(f.review);
  await operation;
  expect(f.session.getSnapshot().review).toBeNull();
  expect(f.native.execute).toHaveBeenCalledTimes(0);
  expect(f.native.cancel).toHaveBeenCalledTimes(1);
});
test("unmount while subscribing releases a late listener and never invokes execute", async () => {
  const f = fixture();
  const gate = deferred<() => void>(f.unlisten);
  f.native.listen = mock(() => gate.promise);
  const operation = f.start();
  await flush();
  f.session.decide(true);
  await flush();
  f.release();
  gate.resolve(f.unlisten);
  await operation;
  expect(f.unlisten).toHaveBeenCalledTimes(1);
  expect(f.native.execute).toHaveBeenCalledTimes(0);
});
test("native modelReloadRequired remains actionable and cannot reach execute", async () => {
  const f = fixture();
  f.native.prepare = mock(async () => {
    throw new Error("plugin.build.modelReloadRequired");
  });
  await f.start();
  expect(f.session.getSnapshot().error).toContain("modelReloadRequired");
  expect(f.native.execute).toHaveBeenCalledTimes(0);
});
test("save failure prevents synchronization and preparation", async () => {
  const f = fixture();
  f.native.save = mock(async () => {
    throw new Error("fixture unsaved buffer");
  });
  await f.start();
  expect(f.native.sync).toHaveBeenCalledTimes(0);
  expect(f.native.prepare).toHaveBeenCalledTimes(0);
  expect(f.session.getSnapshot().error).toContain("unsaved");
});
test("a mismatched native review is disposed rather than presented for approval", async () => {
  const f = fixture();
  f.native.prepare = mock(async () => ({ ...f.review, root: "other" }));
  await f.start();
  expect(f.session.getSnapshot().review).toBeNull();
  expect(f.native.execute).toHaveBeenCalledTimes(0);
  expect(f.native.cancel).toHaveBeenCalledTimes(1);
  expect(f.session.getSnapshot().error).toContain("staleContext");
});
