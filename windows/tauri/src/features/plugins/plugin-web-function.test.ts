import { expect, test } from "bun:test";
import {
  initializePluginWebFunctionListener,
  type WebFunctionPort,
  type WebFunctionRequest,
  type WebFunctionCleanupFailure,
} from "./plugin-web-function";
import type { WebFunctionReview } from "./plugin-web-function-approval";
import { pluginFunctionCleanup } from "./plugin-functions";

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}
const request: WebFunctionRequest = {
  operationId: "native-operation-one",
  pageLabel: "private-plugin-page",
  pageGeneration: 4,
  hostLabel: "workspace-host",
  pluginId: "example.plugin",
  workspaceId: "workspace",
  workspacePath: "/fixture/project",
  instance: "fixture@root",
  function: "snapshot.refresh",
  params: { value: 42 },
  call: "page-call",
  list: false,
};
const review: WebFunctionReview = {
  context: {
    window: request.hostLabel,
    windowIncarnation: 12,
    generation: 3,
    actionId: "__web__:fixture:snapshot.refresh",
    packageIdentity: "package-bytes",
    settingIdentity: "setting-bytes",
    pluginId: request.pluginId,
    functionId: request.function!,
    workspacePath: request.workspacePath,
    operationId: request.operationId,
  },
  executesProjectCode: true,
  mayUseNetwork: true,
  program: {},
  launchPlan: {},
};
function fixture(overrides: Partial<WebFunctionPort> = {}) {
  const calls: Array<{ kind: string; value?: unknown }> = [];
  let receive!: (request: WebFunctionRequest) => Promise<void>;
  let revoked!: (id: string) => void;
  let pluginChanged!: (id: string) => void;
  let cleanupFailed!: (failure: WebFunctionCleanupFailure) => Promise<void>;
  const port: WebFunctionPort = {
    windowLabel: () => request.hostLabel,
    workspace: () => ({ id: request.workspaceId, path: request.workspacePath }),
    guard: () => () => {},
    approval: () => ({
      approve: async () => {
        calls.push({ kind: "approve" });
        return true;
      },
      close: () => calls.push({ kind: "close" }),
    }),
    listen: async (handler) => {
      receive = handler;
      return () => calls.push({ kind: "unlisten" });
    },
    listenCancelled: async (handler) => {
      revoked = handler;
      return () => calls.push({ kind: "unlistenCancelled" });
    },
    listenCleanupFailed: async (handler) => {
      cleanupFailed = handler;
      return () => calls.push({ kind: "unlistenCleanupFailed" });
    },
    readCleanup: async (context) => ({ context, phase: "cleanupFailed" }),
    prepare: async (value) => {
      calls.push({ kind: "prepare", value });
      return review;
    },
    confirm: async (id) => {
      calls.push({ kind: "confirm", value: id });
    },
    cancel: async (id, error, expectedWindowIncarnation) => {
      calls.push({
        kind: "cancel",
        value: {
          id,
          error,
          ...(expectedWindowIncarnation === undefined ? {} : { expectedWindowIncarnation }),
        },
      });
    },
    subscribeWorkspace: () => () => {
      calls.push({ kind: "unsubscribeWorkspace" });
    },
    subscribePlugin: (handler) => {
      pluginChanged = handler;
      return () => calls.push({ kind: "unsubscribePlugin" });
    },
    report: (error) => calls.push({ kind: "report", value: error }),
    ...overrides,
  };
  return {
    port,
    calls,
    receive: (value = request) => receive(value),
    revoke: () => revoked(request.operationId),
    pluginChanged: () => pluginChanged(request.pluginId),
    cleanupFailed: (failure: WebFunctionCleanupFailure) => cleanupFailed(failure),
  };
}
test("web requests prepare their registered native receipt and confirm only after host approval", async () => {
  const f = fixture();
  const dispose = await initializePluginWebFunctionListener(f.port);
  try {
    await f.receive();
    expect(f.calls.map((call) => call.kind)).toEqual(["prepare", "approve", "confirm", "close"]);
    expect(f.calls[0].value).toEqual(request);
    expect(f.calls[2].value).toBe(request.operationId);
  } finally {
    dispose();
  }
});

test("preparation and confirmation failures immediately reach the page with their original codes", async () => {
  const error = {
    code: "plugin.function.failed",
    message: "backend refused",
    pluginErrorCode: "fixture.refused",
  };
  for (const stage of ["prepare", "confirm"] as const) {
    const f = fixture({
      [stage]: async () => {
        throw error;
      },
    });
    const dispose = await initializePluginWebFunctionListener(f.port);
    try {
      await f.receive();
      expect(f.calls.find((call) => call.kind === "cancel")?.value).toEqual({
        id: request.operationId,
        error,
        ...(stage === "confirm"
          ? { expectedWindowIncarnation: review.context.windowIncarnation }
          : {}),
      });
    } finally {
      dispose();
    }
  }
});

test("declining host approval completes the page receipt as cancelled", async () => {
  const f = fixture({ approval: () => ({ approve: async () => false, close: () => {} }) });
  const dispose = await initializePluginWebFunctionListener(f.port);
  try {
    await f.receive();
    expect(f.calls.some((call) => call.kind === "confirm")).toBe(false);
    expect(f.calls.find((call) => call.kind === "cancel")?.value).toEqual({
      id: request.operationId,
      error: { code: "requestCancelled", message: "requestCancelled" },
      expectedWindowIncarnation: review.context.windowIncarnation,
    });
  } finally {
    dispose();
  }
});

test("page cancellation before a late prepare reply never opens approval or confirms", async () => {
  const gate = deferred<WebFunctionReview>();
  const f = fixture({ prepare: () => gate.promise });
  const dispose = await initializePluginWebFunctionListener(f.port);
  const running = f.receive();
  try {
    f.revoke();
    gate.resolve(review);
    await running;
    expect(f.calls.some((call) => call.kind === "approve" || call.kind === "confirm")).toBe(false);
    expect(f.calls.some((call) => call.kind === "cancel")).toBe(true);
  } finally {
    gate.resolve(review);
    dispose();
    await running;
  }
});

test("plugin revocation while approval waits rejects a later acceptance", async () => {
  const gate = deferred<boolean>();
  const entered = deferred<void>();
  let signal: AbortSignal | null = null;
  const f = fixture({
    approval: () => ({
      approve: async (_review, value) => {
        signal = value;
        entered.resolve();
        return gate.promise;
      },
      close: () => {},
    }),
  });
  const dispose = await initializePluginWebFunctionListener(f.port);
  const running = f.receive();
  try {
    await entered.promise;
    f.pluginChanged();
    expect(signal!.aborted).toBe(true);
    gate.resolve(true);
    await running;
    expect(f.calls.some((call) => call.kind === "confirm")).toBe(false);
  } finally {
    gate.resolve(false);
    dispose();
    await running;
  }
});

test("failed listener initialization releases already installed listeners and subscriptions", async () => {
  const f = fixture({
    listenCancelled: async () => {
      throw new Error("fixture listener failed");
    },
  });
  await expect(initializePluginWebFunctionListener(f.port)).rejects.toThrow(
    "fixture listener failed",
  );
  expect(f.calls.map((call) => call.kind)).toEqual(["unsubscribePlugin", "unsubscribeWorkspace"]);
});

const cleanupError = {
  code: "plugin.function.cleanupFailed",
  message: "plugin.function.cleanupFailed",
};
const staleError = {
  code: "plugin.function.staleContext",
  message: "plugin.function.staleContext",
};
const event: WebFunctionCleanupFailure = {
  operationId: request.operationId,
  context: review.context,
  error: cleanupError,
};
const webNotices = () =>
  pluginFunctionCleanup
    .pending()
    .filter((owner) => owner.input.operationId === request.operationId);

test("native cleanup failure after approval removal stays retryable and duplicate events share its exact receipt", async () => {
  let present = true;
  const f = fixture({
    readCleanup: async (context) => (present ? { context, phase: "cleanupFailed" } : null),
  });
  const dispose = await initializePluginWebFunctionListener(f.port);
  try {
    await f.receive();
    expect(f.calls.some((call) => call.kind === "close")).toBe(true);
    await f.cleanupFailed(event);
    await f.cleanupFailed(event);
    expect(webNotices()).toHaveLength(1);
    dispose();
    await webNotices()[0].cancel();
    expect(f.calls.find((call) => call.kind === "cancel")?.value).toEqual({
      id: request.operationId,
      error: undefined,
      expectedWindowIncarnation: review.context.windowIncarnation,
    });
    expect(webNotices()).toHaveLength(0);
    present = false;
    await f.cleanupFailed(event);
    expect(webNotices()).toHaveLength(0);
  } finally {
    for (const owner of webNotices()) await owner.cancel();
    dispose();
  }
});

test("failed active cancellation and native event deduplicate; failed retries remain visible until original owner releases", async () => {
  let succeeds = false;
  const attempts: Array<[string, number | undefined]> = [];
  const f = fixture({
    approval: () => ({ approve: async () => false, close: () => {} }),
    cancel: async (id, _error, incarnation) => {
      attempts.push([id, incarnation]);
      if (!succeeds) throw cleanupError;
    },
    readCleanup: async () => {
      throw new Error("temporary receipt read failure");
    },
  });
  const dispose = await initializePluginWebFunctionListener(f.port);
  try {
    await f.receive();
    await f.cleanupFailed(event);
    expect(webNotices()).toHaveLength(1);
    const owner = webNotices()[0];
    await owner.cancel();
    expect(webNotices()).toEqual([owner]);
    expect(owner.state.phase).toBe("cleanupFailed");
    succeeds = true;
    await owner.cancel();
    expect(webNotices()).toHaveLength(0);
    expect(attempts).toEqual(
      Array.from({ length: 3 }, () => [request.operationId, review.context.windowIncarnation]),
    );
  } finally {
    succeeds = true;
    for (const owner of webNotices()) await owner.cancel();
    dispose();
  }
});

test("an old incarnation cleanup event cannot retain a replacement owner's receipt", async () => {
  const f = fixture({
    readCleanup: async (context) => ({
      context: { ...context, windowIncarnation: context.windowIncarnation + 1 },
      phase: "cleanupFailed",
    }),
  });
  const dispose = await initializePluginWebFunctionListener(f.port);
  try {
    await f.cleanupFailed(event);
    expect(webNotices()).toHaveLength(0);
    expect(f.calls.some((call) => call.kind === "cancel")).toBe(false);
  } finally {
    dispose();
  }
});

test("a failure snapshot already in flight cannot recreate a notice after retry succeeds", async () => {
  type Snapshot = Awaited<ReturnType<WebFunctionPort["readCleanup"]>>;
  const firstRead = deferred<Snapshot>();
  const delayedRead = deferred<Snapshot>();
  const snapshot: Snapshot = { context: review.context, phase: "cleanupFailed" };
  let reads = 0;
  const f = fixture({
    readCleanup: () => (++reads === 1 ? firstRead.promise : delayedRead.promise),
  });
  const dispose = await initializePluginWebFunctionListener(f.port);
  // Both native reads start before the first failure notice has an owner.
  const firstFailure = f.cleanupFailed(event);
  const delayedFailure = f.cleanupFailed(event);
  try {
    expect(reads).toBe(2);
    firstRead.resolve(snapshot);
    await firstFailure;
    expect(webNotices()).toHaveLength(1);
    await webNotices()[0].cancel();
    expect(webNotices()).toHaveLength(0);
    delayedRead.resolve(snapshot);
    await delayedFailure;
    expect(webNotices()).toHaveLength(0);
  } finally {
    firstRead.resolve(snapshot);
    delayedRead.resolve(snapshot);
    await Promise.all([firstFailure, delayedFailure]);
    for (const owner of webNotices()) await owner.cancel();
    dispose();
  }
}, 3000);

test("retry releases a web cleanup notice when lifecycle cleanup already removed its exact receipt", async () => {
  let present = true;
  const reads: Array<WebFunctionReview["context"]> = [];
  const attempts: Array<[string, number | undefined]> = [];
  const f = fixture({
    cancel: async (id, _error, incarnation) => {
      attempts.push([id, incarnation]);
      throw staleError;
    },
    readCleanup: async (context) => {
      reads.push(context);
      return present ? { context, phase: "cleanupFailed" } : null;
    },
  });
  const dispose = await initializePluginWebFunctionListener(f.port);
  try {
    await f.cleanupFailed(event);
    expect(webNotices()).toHaveLength(1);
    // Closing the workspace completes native cleanup before the user retries.
    present = false;
    await webNotices()[0].cancel();
    expect(webNotices()).toHaveLength(0);
    expect(reads).toEqual([review.context, review.context]);
    expect(attempts).toEqual([[request.operationId, review.context.windowIncarnation]]);
  } finally {
    present = false;
    for (const owner of webNotices()) await owner.cancel();
    dispose();
  }
}, 3000);

test("stale retries retain a present or unreadable receipt and other cleanup failures cannot release it", async () => {
  let state: "present" | "unreadable" | "absent" = "present";
  let failure = staleError;
  let succeeds = false;
  let reads = 0;
  const f = fixture({
    cancel: async () => {
      if (!succeeds) throw failure;
    },
    readCleanup: async (context) => {
      reads++;
      if (state === "unreadable") throw new Error("temporary receipt read failure");
      return state === "present" ? { context, phase: "cleanupFailed" } : null;
    },
  });
  const dispose = await initializePluginWebFunctionListener(f.port);
  try {
    await f.cleanupFailed(event);
    const owner = webNotices()[0];
    await owner.cancel();
    expect(webNotices()).toEqual([owner]);
    expect(owner.state.phase).toBe("cleanupFailed");
    state = "unreadable";
    await owner.cancel();
    expect(webNotices()).toEqual([owner]);
    expect(owner.state.phase).toBe("cleanupFailed");
    state = "absent";
    failure = cleanupError;
    await owner.cancel();
    expect(webNotices()).toEqual([owner]);
    expect(owner.state.error).toEqual(cleanupError);
    expect(reads).toBe(3);
  } finally {
    succeeds = true;
    for (const owner of webNotices()) await owner.cancel();
    dispose();
  }
}, 3000);
