import { afterEach, expect, mock, test } from "bun:test";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { useBuildSystemsStore } from "@/features/build-systems/build-systems-store";
import { useBuildOutputStore } from "@/features/build-systems/output/build-output-store";
import { cancelBuildModel, loadBuildModel } from "@/features/build-systems/build-systems-service";
import * as lspAdapter from "@/platform/lsp-core-adapter";
import type { BuildRunNative } from "@/features/build-systems/build-run-native";
import type { BuildRunReview } from "@/features/build-systems/build-run-types";
import type {
  BuildOutputEvent,
  BuildRunTerminal,
} from "@/features/build-systems/output/build-output-types";
import type { BuildView } from "@/features/build-systems/build-systems-types";
import { runPluginWebBuildWorkflow, type WebBuildWorkflowPort } from "./plugin-web-build-workflow";
import type { PluginWebBuildRequest } from "./plugin-web-build";
import type { BuildRunSession } from "@/features/build-systems/build-run-session";
import { initializePluginWebBuildListener, type PluginWebBuildPort } from "./plugin-web-build";

const sharedLanguageStart = mock(
  async (_args: unknown, _signal?: AbortSignal): Promise<void> => {},
);
mock.module("@/platform/lsp-core-adapter", () => ({
  ...lspAdapter,
  ensureBuildProviderLanguageSession: sharedLanguageStart,
}));
mock.module("@/platform/tauri-core", () => ({ invoke: mock(async () => ({})) }));

const release: Array<() => void> = [];
const work: Promise<unknown>[] = [];
let sequence = 0;
function deferred<T>(fallback: T) {
  let resolve!: (value: T) => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((yes, no) => {
    resolve = yes;
    reject = no;
  });
  release.push(() => resolve(fallback));
  return { promise, resolve, reject };
}
async function flush() {
  for (let turn = 0; turn < 32; turn++) await Promise.resolve();
}
afterEach(async () => {
  for (const cleanup of release.splice(0).reverse()) cleanup();
  await Promise.allSettled(work.splice(0));
  await flush();
  workspaceRuntimeRegistry.resetForTests();
  sharedLanguageStart.mockImplementation(async () => {});
});
function fixture(method: PluginWebBuildRequest["method"] = "build.runTask") {
  const id = `web-workflow-${++sequence}`,
    plugin = "fixture.plugin",
    root = `C:/fixture/${id}`;
  workspaceRuntimeRegistry.activateWorkspace({ id, path: root, name: id }, "ready");
  const store = useBuildSystemsStore.getStore(id);
  const view: BuildView = {
    generation: 5,
    workspaceRoot: root,
    issues: [],
    instances: [
      {
        pluginID: plugin,
        buildSystemID: "fixture",
        root: ".",
        displayName: "Fixture",
        markers: [],
        modelSource: "command",
        model: { projects: [{ id: "project", path: ".", name: "App" }] },
        options: [],
        syncDigest: "sync",
        optionFingerprint: "options",
        stale: false,
      },
    ],
  };
  store.getState().actions.applyView(view, store.getState().actions.beginRequest());
  const request: PluginWebBuildRequest = {
    operationId: `request-${sequence}`,
    pluginId: plugin,
    pageLabel: "page-a",
    pageGeneration: 1,
    hostLabel: "main",
    workspaceId: id,
    workspacePath: root,
    method,
  };
  const controller = new AbortController();
  release.push(() => controller.abort());
  const review: BuildRunReview & { projectId: string } = {
    operationId: `native-${sequence}`,
    pluginId: plugin,
    buildSystemId: "fixture",
    workspaceRoot: root,
    projectId: "project",
    root: ".",
    generation: 5,
    kind:
      method === "build.runTests"
        ? "test"
        : method === "build.dependencies"
          ? "dependencies"
          : "task",
    title: "Fixture",
    executesProjectCode: true,
    mayUseNetwork: true,
  };
  let context = {
    pluginId: plugin,
    buildSystemId: "fixture",
    root: ".",
    workspaceRoot: root,
    modelSource: "command",
    selection: {
      kind: review.kind,
      taskId: "build",
      projectId: "project",
      targetId: null,
      modelTaskId: null,
      suite: null,
      case: null,
      userArguments: [],
    },
  };
  const decision = deferred(false),
    terminal = deferred<BuildRunTerminal>({ kind: "cancelled", exitCode: null });
  const prepared = deferred<BuildRunReview | null>(null);
  let delayPrepare = false,
    cancelFails = false;
  const order: string[] = [],
    shown: string[] = [],
    sinks: Array<(value: BuildOutputEvent) => void> = [];
  let retry: (() => Promise<void>) | null = null;
  let releaseListener = 0;
  let shownRun: BuildRunSession | null = null;
  release.push(() => {
    cancelFails = false;
    if (shownRun) {
      const done = shownRun.cancel();
      work.push(done);
      void done.catch(() => {});
    }
  });
  const native: BuildRunNative = {
    windowLabel: () => "main",
    definition: async () => {
      order.push("definition");
      return { tasks: [], programs: [{ kind: "buildSystem" }] };
    },
    save: async () => {
      order.push("save");
    },
    sync: async () => {
      order.push("sync");
      store.getState().actions.applyView(view, store.getState().actions.beginRequest());
    },
    prepare: async () => {
      throw new Error("must use the page-bound native adapter");
    },
    execute: async () => {
      throw new Error("must use the page-bound native adapter");
    },
    cancel: async () => {
      throw new Error("must use the page-bound native adapter");
    },
    listen: async (_label, sink) => {
      order.push("listen");
      sinks.push(sink);
      return () => {
        releaseListener++;
      };
    },
    scheduleOutputDrain: (callback) => {
      callback();
      return () => {};
    },
  };
  const port: WebBuildWorkflowPort = {
    native,
    loadModel: loadBuildModel,
    cancelModel: cancelBuildModel,
    action: async <T>(_token: string, phase: string): Promise<T> => {
      expect(_token).toBe(request.operationId);
      order.push(phase);
      if (phase === "inspect") return context as T;
      if (phase === "prepare") return (delayPrepare ? await prepared.promise : review) as T;
      if (phase === "cancel") {
        if (cancelFails) throw new Error("cleanup failed");
        terminal.resolve({ kind: "cancelled", exitCode: null });
        return {} as T;
      }
      if (phase === "execute") {
        if (method === "build.refresh")
          return { operationId: review.operationId, view, stderr: "" } as T;
        const result = await terminal.promise;
        sinks[sinks.length - 1]?.({ ...review, type: "terminal", terminal: result });
        return (
          method === "build.dependencies"
            ? {
                ...review,
                projectId: "project",
                terminal: result,
                dependencies:
                  result.kind === "succeeded" ? [{ name: "dependency", children: [] }] : null,
                truncated: false,
              }
            : result
        ) as T;
      }
      if (phase === "staticRefresh") return view as T;
      return {} as T;
    },
    approval: async () => ({
      approve: async (_review, _programs, signal) => {
        order.push("approval");
        if (signal.aborted) return false;
        return new Promise<boolean>((resolve) => {
          const abort = () => resolve(false);
          signal.addEventListener("abort", abort, { once: true });
          void decision.promise.then((value) => {
            signal.removeEventListener("abort", abort);
            resolve(value);
          });
        });
      },
      show: (session) => {
        shownRun = session;
        shown.push(session.getSnapshot().phase);
      },
      close: () => {
        order.push("close");
      },
      failed: (_error, retryCancel) => {
        retry = retryCancel;
      },
    }),
  };
  const start = () => {
    const promise = runPluginWebBuildWorkflow(
      request,
      { id, path: root, store },
      controller.signal,
      port,
    );
    work.push(promise);
    void promise.catch(() => {});
    return promise;
  };
  return {
    port,
    request,
    controller,
    store,
    id,
    review,
    order,
    shown,
    decision,
    terminal,
    prepared,
    native,
    start,
    retry: () => retry,
    listenerReleased: () => releaseListener,
    retryRetained: () => shownRun!.cancel(),
    delayPrepare: () => {
      delayPrepare = true;
    },
    cancelFails: (value: boolean) => {
      cancelFails = value;
    },
    context: (patch: Partial<typeof context>) => {
      context = { ...context, ...patch };
    },
  };
}

test("task uses save sync review listener sync execute in the existing session", async () => {
  const f = fixture();
  const pending = f.start();
  await flush();
  expect(f.order).toEqual(["inspect", "save", "sync", "definition", "prepare", "approval"]);
  f.decision.resolve(true);
  await flush();
  expect(f.order.slice(-3)).toEqual(["listen", "sync", "execute"]);
  f.terminal.resolve({ kind: "succeeded", exitCode: null });
  await pending;
  expect(f.shown).toContain("running");
  expect(f.listenerReleased()).toBe(1);
});
test("tests use the same native workflow and retain the test selection kind", async () => {
  const f = fixture("build.runTests");
  const pending = f.start();
  await flush();
  expect(f.review.kind).toBe("test");
  f.decision.resolve(true);
  await flush();
  f.terminal.resolve({ kind: "failed", exitCode: null });
  await pending;
  expect(f.order).toContain("execute");
});
test("decline releases the prepared owner without subscribing or executing", async () => {
  const f = fixture();
  const pending = f.start();
  await flush();
  f.decision.resolve(false);
  await expect(pending).rejects.toThrow("cancelled");
  expect(f.order).toContain("cancel");
  expect(f.order).not.toContain("execute");
  expect(f.order).not.toContain("listen");
});
test("dependencies reuse the shared run session and finish only after Core results", async () => {
  const f = fixture("build.dependencies");
  const pending = f.start();
  await flush();
  f.decision.resolve(true);
  await flush();
  expect(f.order).not.toContain("finish");
  f.terminal.resolve({ kind: "succeeded", exitCode: null });
  await pending;
  expect(f.order[f.order.length - 1]).toBe("finish");
});
test("command refresh uses the existing load-model consent and native port", async () => {
  const f = fixture("build.refresh");
  const pending = f.start();
  await flush();
  expect(f.order).not.toContain("execute");
  f.decision.resolve(true);
  await pending;
  expect(f.order).toContain("prepare");
  expect(f.order).toContain("execute");
  expect(f.order).toContain("finish");
});
function useSharedProvider(f: ReturnType<typeof fixture>) {
  f.review.provider = {
    token: 7,
    context: {
      window: "main",
      workspaceRoot: f.review.workspaceRoot,
      generation: f.review.generation,
      pluginId: f.review.pluginId,
      packageIdentity: "fixture:digest",
      buildSystem: f.review.buildSystemId,
      instanceRoot: f.review.root,
      instanceDirectory: f.review.workspaceRoot,
    },
    executesProjectCode: true,
    mayUseNetwork: true,
    launchPlan: { buildProvider: { languageServer: "fixture-language" } },
    program: {
      pluginId: f.review.pluginId,
      languageId: "fixture-language",
      serverPath: "fixture-language-server.exe",
      serverArgs: [],
      environment: {},
    },
  };
}

test("page model Retry retains busy ownership until the original shared LSP cleanup succeeds", async () => {
  const f = fixture("build.refresh");
  useSharedProvider(f);
  const cleanup = deferred<void>(undefined);
  let retryFails = true;
  let attempts = 0;
  const retryCleanup = async () => {
    attempts++;
    if (retryFails) throw new Error("plugin.build.cleanupFailed");
    await cleanup.promise;
  };
  sharedLanguageStart.mockImplementation(async () => {
    throw Object.assign(new Error("plugin.build.cleanupFailed"), { retryCleanup });
  });
  release.push(() => {
    retryFails = false;
    cleanup.resolve(undefined);
    const retry = f.retry()?.();
    if (retry) {
      work.push(retry);
      void retry.catch(() => {});
    }
  });
  const pending = f.start();
  f.decision.resolve(true);
  await expect(pending).rejects.toThrow("plugin.build.cleanupFailed");
  expect(f.order).not.toContain("execute");
  expect(f.retry()).not.toBeNull();

  await expect(f.retry()!()).rejects.toThrow("plugin.build.cleanupFailed");
  expect(attempts).toBe(1);
  await expect(f.start()).rejects.toThrow("plugin.build.busy");
  retryFails = false;
  let cleaned = false;
  const retry = f.retry()!().then(() => {
    cleaned = true;
  });
  work.push(retry);
  await flush();
  expect(attempts).toBe(2);
  expect(cleaned).toBe(false);
  await expect(f.start()).rejects.toThrow("plugin.build.busy");
  cleanup.resolve(undefined);
  await retry;
  sharedLanguageStart.mockImplementation(async () => {});
  await f.start();
  expect(f.order).toContain("execute");
});

test("page revocation cancels the exact prepared model owner before releasing a shared initializer", async () => {
  const f = fixture("build.refresh");
  useSharedProvider(f);
  const started = deferred<void>(undefined);
  const shared = deferred<void>(undefined);
  const cancelled: string[] = [];
  const retryCleanup = mock(async () => {});
  sharedLanguageStart.mockImplementation(async () => {
    started.resolve(undefined);
    await shared.promise;
  });
  f.port.cancelModel = async (operationId) => {
    cancelled.push(operationId);
    await cancelBuildModel(operationId);
  };
  release.push(() => {
    shared.resolve(undefined);
    const retry = f.retry()?.();
    if (retry) {
      work.push(retry);
      void retry.catch(() => {});
    }
  });
  const pending = f.start();
  f.decision.resolve(true);
  await started.promise;
  f.controller.abort();
  shared.reject(Object.assign(new Error("plugin.build.cleanupFailed"), { retryCleanup }));
  await expect(pending).rejects.toThrow("plugin.build.cleanupFailed");
  expect(cancelled).toContain(f.review.operationId);
  expect(f.order).not.toContain("execute");
  await f.retry()!();
  expect(retryCleanup).toHaveBeenCalledTimes(1);
  expect(cancelled.every((id) => id === f.review.operationId)).toBe(true);
});

test("static refresh saves then synchronizes and performs real model refresh", async () => {
  const f = fixture("build.refresh");
  f.context({ modelSource: "static" });
  await f.start();
  expect(f.order).toEqual(["inspect", "save", "sync", "staticRefresh", "finish", "close"]);
});
test("cancel only inspects the native page-owned run and opens no approval", async () => {
  const f = fixture("build.cancel");
  await f.start();
  expect(f.order).toEqual(["inspect"]);
});
test("wrong plugin/workspace contexts fail before save or approval", async () => {
  const f = fixture();
  f.context({ pluginId: "foreign" });
  await expect(f.start()).rejects.toThrow("staleContext");
  expect(f.order).toEqual(["inspect"]);
});
test("a busy host store rejects a second page without cancelling existing work", async () => {
  const f = fixture();
  f.store.getState().actions.beginRequest();
  await expect(f.start()).rejects.toThrow("busy");
  expect(f.order).toEqual(["inspect"]);
});
test("revocation while waiting for approval never reaches subscription or execute", async () => {
  const f = fixture();
  const pending = f.start();
  await flush();
  f.controller.abort();
  await Promise.allSettled([pending]);
  f.decision.resolve(true);
  await flush();
  expect(f.order).not.toContain("execute");
  expect(f.order).toContain("cancel");
});
test("late prepare after close is cancelled through the same bound token", async () => {
  const f = fixture();
  f.delayPrepare();
  const pending = f.start();
  await flush();
  f.controller.abort();
  f.prepared.resolve(f.review);
  await Promise.allSettled([pending]);
  expect(f.order).not.toContain("approval");
  expect(f.order).not.toContain("execute");
  expect(f.order).toContain("cancel");
});
test("cancellation failure retains busy owner and retry uses the original token", async () => {
  const f = fixture();
  f.cancelFails(true);
  const pending = f.start();
  await flush();
  f.decision.resolve(false);
  await Promise.allSettled([pending]);
  expect(f.order.filter((item) => item === "cancel")).toHaveLength(1);
  expect(f.store.getState().status).toBe("loading");
  f.cancelFails(false);
  await f.retryRetained();
  await flush();
  // Retained product session is shown; its Stop control owns retry. Resolving
  // the terminal in teardown prevents any pending fixture operation escaping.
  expect(f.shown).toContain("cancelFailed");
});
test("a late subscription is released and cannot execute after revocation", async () => {
  const f = fixture();
  const listener = deferred<() => void>(() => {});
  let released = 0;
  f.native.listen = async () => {
    f.order.push("listen-gated");
    return listener.promise;
  };
  const pending = f.start();
  await flush();
  f.decision.resolve(true);
  await flush();
  f.controller.abort();
  listener.resolve(() => {
    released++;
  });
  await Promise.allSettled([pending]);
  expect(released).toBe(1);
  expect(f.order).not.toContain("execute");
});

test("workbench listener wires a page request and revocation into the real run session", async () => {
  const f = fixture();
  let receive!: (request: PluginWebBuildRequest) => void;
  let revoke!: (id: string) => void;
  const refusals: string[] = [];
  const port: PluginWebBuildPort = {
    windowLabel: () => "main",
    workspace: () => ({ id: f.id, path: f.request.workspacePath, store: f.store }),
    listen: async (handler) => {
      receive = handler;
      return () => {};
    },
    listenRevoked: async (handler) => {
      revoke = handler;
      return () => {};
    },
    handle: async (id, accept) => {
      if (!accept) refusals.push(id);
      return null;
    },
    complete: async () => {},
    workflow: (request, workspace, signal) => {
      const pending = runPluginWebBuildWorkflow(request, workspace, signal, f.port);
      work.push(pending);
      void pending.catch(() => {});
      return pending;
    },
    subscribeWorkspace: () => () => {},
    subscribePlugin: () => () => {},
    pluginGuard: () => () => {},
    scheduleDeadline: () => () => {},
    report: () => {},
  };
  const cleanup = await initializePluginWebBuildListener(port);
  release.push(cleanup);
  receive(f.request);
  await flush();
  expect(f.order).toContain("approval");
  revoke(f.request.operationId);
  await flush();
  f.decision.resolve(true);
  await flush();
  expect(refusals).toContain(f.request.operationId);
  expect(f.order).toContain("cancel");
  expect(f.order).not.toContain("execute");
});
