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
