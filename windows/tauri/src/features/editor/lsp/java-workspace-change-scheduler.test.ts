import { expect, mock, test } from "bun:test";
import type { JavaWorkspacePolicy } from "@/platform/java-workspace-policy";
import { JavaWorkspaceChangeScheduler } from "./java-workspace-change-scheduler";

class ManualTimer {
  private nextId = 1;
  private readonly callbacks = new Map<number, () => void | Promise<void>>();

  readonly set = (callback: () => void | Promise<void>) => {
    const id = this.nextId++;
    this.callbacks.set(id, callback);
    return id as unknown as ReturnType<typeof setTimeout>;
  };

  readonly clear = (timer: ReturnType<typeof setTimeout>) => {
    this.callbacks.delete(timer as unknown as number);
  };

  get size(): number {
    return this.callbacks.size;
  }

  async fireNext(): Promise<void> {
    const id = [...this.callbacks.keys()].sort((left, right) => left - right)[0];
    if (id === undefined) throw new Error("No timer is scheduled.");
    const callback = this.callbacks.get(id);
    this.callbacks.delete(id);
    await callback?.();
  }
}

function deferred<T>() {
  let resolve: (value: T) => void = () => undefined;
  const promise = new Promise<T>((complete) => {
    resolve = complete;
  });
  return { promise, resolve };
}

function policyFor(paths: string[], kind: "source" | "buildConfiguration"): JavaWorkspacePolicy {
  return {
    shouldStart: false,
    changes: paths.map((path) => ({ path, kind })),
  };
}

function operationRecorder() {
  const records: Array<{ operationId: string; outcome: string; details?: unknown }> = [];
  return {
    records,
    factory: (operationId: string) => ({
      succeeded: (details?: Record<string, unknown>) =>
        records.push({ operationId, outcome: "succeeded", details }),
      failed: (reason: unknown) => records.push({ operationId, outcome: "failed", details: reason }),
      cancelled: (reason: string) =>
        records.push({ operationId, outcome: "cancelled", details: reason }),
    }),
  };
}

test("debounces and coalesces watcher changes into one Core policy operation", async () => {
  const timer = new ManualTimer();
  const notify = mock(async () => undefined);
  const resolvePolicy = mock(async (_workspacePaths: string[], changedPaths: string[]) =>
    policyFor(changedPaths, "source"),
  );
  const operations = operationRecorder();
  const scheduler = new JavaWorkspaceChangeScheduler({
    resolvePolicy,
    notify,
    createOperationLog: operations.factory,
    setTimer: timer.set,
    clearTimer: timer.clear,
  });

  scheduler.schedule("workspace-1", "C:/work", {
    path: "C:/work/src/Main.java",
    kind: "created",
    includeSource: false,
  });
  scheduler.schedule("workspace-1", "C:/work", {
    path: "C:/work/src/Main.java",
    kind: "changed",
    includeSource: true,
  });

  expect(timer.size).toBe(1);
  await timer.fireNext();
  expect(resolvePolicy).toHaveBeenCalledTimes(1);
  expect(resolvePolicy).toHaveBeenCalledWith([], ["src/Main.java"]);
  expect(notify).toHaveBeenCalledWith("C:/work", [
    { path: "C:/work/src/Main.java", kind: "changed" },
  ]);
  expect(operations.records).toEqual([
    expect.objectContaining({ outcome: "succeeded" }),
  ]);
});

test("drops workspace-root events before resolving the Core file policy", async () => {
  const timer = new ManualTimer();
  const notify = mock(async () => undefined);
  const resolvePolicy = mock(async (_workspacePaths: string[], changedPaths: string[]) =>
    policyFor(changedPaths, "source"),
  );
  const operations = operationRecorder();
  const scheduler = new JavaWorkspaceChangeScheduler({
    resolvePolicy,
    notify,
    createOperationLog: operations.factory,
    setTimer: timer.set,
    clearTimer: timer.clear,
  });

  scheduler.schedule("workspace-1", "C:/work", {
    path: "C:/work",
    kind: "changed",
    includeSource: true,
  });
  scheduler.schedule("workspace-1", "C:/work", {
    path: "C:/work/src/Main.java",
    kind: "changed",
    includeSource: true,
  });

  await timer.fireNext();

  expect(resolvePolicy).toHaveBeenCalledWith([], ["src/Main.java"]);
  expect(notify).toHaveBeenCalledWith("C:/work", [
    { path: "C:/work/src/Main.java", kind: "changed" },
  ]);
  expect(operations.records).toEqual([
    expect.objectContaining({ outcome: "succeeded" }),
  ]);
});

test("finishes a root-only watcher batch without calling Core", async () => {
  const timer = new ManualTimer();
  const resolvePolicy = mock(async () => policyFor([], "source"));
  const notify = mock(async () => undefined);
  const operations = operationRecorder();
  const scheduler = new JavaWorkspaceChangeScheduler({
    resolvePolicy,
    notify,
    createOperationLog: operations.factory,
    setTimer: timer.set,
    clearTimer: timer.clear,
  });

  scheduler.schedule("workspace-1", "C:/work/", {
    path: "C:\\work",
    kind: "changed",
    includeSource: true,
  });

  await timer.fireNext();

  expect(resolvePolicy).not.toHaveBeenCalled();
  expect(notify).not.toHaveBeenCalled();
  expect(operations.records).toEqual([
    expect.objectContaining({ outcome: "cancelled", details: "no-workspace-contained-paths" }),
  ]);
});

test("cancels a scheduled timer when its workspace closes", () => {
  const timer = new ManualTimer();
  const operations = operationRecorder();
  const scheduler = new JavaWorkspaceChangeScheduler({
    resolvePolicy: async () => policyFor([], "source"),
    notify: async () => undefined,
    createOperationLog: operations.factory,
    setTimer: timer.set,
    clearTimer: timer.clear,
  });

  scheduler.schedule("workspace-1", "C:/work", {
    path: "C:/work/pom.xml",
    kind: "changed",
    includeSource: false,
  });
  scheduler.cancel("workspace-1");

  expect(timer.size).toBe(0);
  expect(operations.records).toEqual([
    expect.objectContaining({ outcome: "cancelled", details: "workspace-closed" }),
  ]);
});

test("cancels an in-flight policy resolution without notifying JDTLS", async () => {
  const timer = new ManualTimer();
  const pendingPolicy = deferred<JavaWorkspacePolicy>();
  const notify = mock(async () => undefined);
  const operations = operationRecorder();
  const scheduler = new JavaWorkspaceChangeScheduler({
    resolvePolicy: async () => pendingPolicy.promise,
    notify,
    createOperationLog: operations.factory,
    setTimer: timer.set,
    clearTimer: timer.clear,
  });

  scheduler.schedule("workspace-1", "C:/work", {
    path: "C:/work/pom.xml",
    kind: "changed",
    includeSource: false,
  });
  const flush = timer.fireNext();
  scheduler.cancel("workspace-1");
  pendingPolicy.resolve(policyFor(["pom.xml"], "buildConfiguration"));
  await flush;

  expect(notify).not.toHaveBeenCalled();
  expect(operations.records).toEqual([
    expect.objectContaining({ outcome: "cancelled", details: "workspace-closed" }),
  ]);
});

test("supersedes a stale flush and carries its changes into the next batch", async () => {
  const timer = new ManualTimer();
  const firstPolicy = deferred<JavaWorkspacePolicy>();
  let policyCallCount = 0;
  const resolvePolicy = mock(async (_workspacePaths: string[], changedPaths: string[]) => {
    policyCallCount += 1;
    if (policyCallCount === 1) return firstPolicy.promise;
    return policyFor(changedPaths, "buildConfiguration");
  });
  const notify = mock(async () => undefined);
  const operations = operationRecorder();
  const scheduler = new JavaWorkspaceChangeScheduler({
    resolvePolicy,
    notify,
    createOperationLog: operations.factory,
    setTimer: timer.set,
    clearTimer: timer.clear,
  });

  scheduler.schedule("workspace-1", "C:/work", {
    path: "C:/work/pom.xml",
    kind: "changed",
    includeSource: false,
  });
  const staleFlush = timer.fireNext();
  scheduler.schedule("workspace-1", "C:/work", {
    path: "C:/work/settings.gradle",
    kind: "created",
    includeSource: false,
  });
  firstPolicy.resolve(policyFor(["pom.xml"], "buildConfiguration"));
  await staleFlush;

  expect(notify).not.toHaveBeenCalled();
  await timer.fireNext();
  expect(notify).toHaveBeenCalledWith(
    "C:/work",
    expect.arrayContaining([
      { path: "C:/work/pom.xml", kind: "changed" },
      { path: "C:/work/settings.gradle", kind: "created" },
    ]),
  );
  expect(operations.records.map((record) => record.outcome)).toEqual([
    "cancelled",
    "succeeded",
  ]);
  expect(new Set(operations.records.map((record) => record.operationId)).size).toBe(2);
});

test("records a failed terminal outcome when notification fails", async () => {
  const timer = new ManualTimer();
  const operations = operationRecorder();
  const scheduler = new JavaWorkspaceChangeScheduler({
    resolvePolicy: async (_workspacePaths, changedPaths) =>
      policyFor(changedPaths, "buildConfiguration"),
    notify: async () => {
      throw new Error("notification failed");
    },
    createOperationLog: operations.factory,
    setTimer: timer.set,
    clearTimer: timer.clear,
  });

  scheduler.schedule("workspace-1", "C:/work", {
    path: "C:/work/pom.xml",
    kind: "changed",
    includeSource: false,
  });
  await timer.fireNext();

  expect(operations.records).toEqual([
    expect.objectContaining({ outcome: "failed" }),
  ]);
});

// Regression: every other test injects `clearTimer`, so the production default
// was never exercised. Assigning the bare `clearTimeout` reference to an
// instance field makes WebView2 receive the scheduler as `this` and reject the
// call with "Illegal invocation", which aborted `schedule` before it recorded
// the change or re-armed the debounce timer.
test("clears the debounce timer without passing the scheduler as the receiver", async () => {
  const timer = new ManualTimer();
  const notify = mock(async () => undefined);
  const operations = operationRecorder();
  const originalClearTimeout = globalThis.clearTimeout;
  const receivers: unknown[] = [];
  // Mimics WebView2, which throws unless the receiver is the window.
  globalThis.clearTimeout = function replacedClearTimeout(
    this: unknown,
    handle?: ReturnType<typeof setTimeout>,
  ) {
    receivers.push(this);
    if (this !== undefined && this !== globalThis) {
      throw new TypeError("Illegal invocation");
    }
    timer.clear(handle as ReturnType<typeof setTimeout>);
  } as typeof globalThis.clearTimeout;

  try {
    const scheduler = new JavaWorkspaceChangeScheduler({
      resolvePolicy: async (_workspacePaths, changedPaths) =>
        policyFor(changedPaths, "buildConfiguration"),
      notify,
      createOperationLog: operations.factory,
      setTimer: timer.set,
      // `clearTimer` is intentionally left to the production default.
    });

    scheduler.schedule("workspace-1", "C:/work", {
      path: "C:/work/pom.xml",
      kind: "created",
      includeSource: false,
    });
    // The second call takes the branch that clears the armed timer.
    scheduler.schedule("workspace-1", "C:/work", {
      path: "C:/work/ruoyi-admin/pom.xml",
      kind: "changed",
      includeSource: false,
    });

    expect(receivers).toEqual([undefined]);
    expect(timer.size).toBe(1);

    await timer.fireNext();

    // Both paths survive, proving `schedule` was not aborted mid-way.
    expect(notify).toHaveBeenCalledWith("C:/work", [
      { path: "C:/work/pom.xml", kind: "created" },
      { path: "C:/work/ruoyi-admin/pom.xml", kind: "changed" },
    ]);
    expect(operations.records).toEqual([expect.objectContaining({ outcome: "succeeded" })]);
  } finally {
    globalThis.clearTimeout = originalClearTimeout;
  }
});
