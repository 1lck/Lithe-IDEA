import { expect, mock, test } from "bun:test";
import { JavaWorkspaceLanguageServerOwner } from "./java-workspace-language-server";

function operationRecorder() {
  const outcomes: string[] = [];
  const operationIds: string[] = [];
  const names: string[] = [];
  return {
    outcomes,
    operationIds,
    names,
    factory: (name: string, operationId: string) => {
      names.push(name);
      operationIds.push(operationId);
      return {
        succeeded: () => outcomes.push("succeeded"),
        failed: () => outcomes.push("failed"),
        cancelled: () => outcomes.push("cancelled"),
        timedOut: () => outcomes.push("timedOut"),
      };
    },
  };
}

test("shares one Java workspace prewarm and reports readiness once", async () => {
  let releaseStart: ((outcome: { kind: "ready" }) => void) | undefined;
  const start = mock(
    () =>
      new Promise<{ kind: "ready" }>((resolve) => {
        releaseStart = resolve;
      }),
  );
  const stop = mock(async () => undefined);
  const notifyReady = mock(() => undefined);
  const notifyPreparing = mock(() => undefined);
  const operations = operationRecorder();
  const owner = new JavaWorkspaceLanguageServerOwner(
    { start, stop },
    operations.factory,
    notifyReady,
    () => undefined,
    notifyPreparing,
    () => undefined,
  );

  const first = owner.prewarm("C:/work", "C:/work/src/Main.java");
  const second = owner.prewarm("C:\\work", "C:/work/src/Other.java");
  expect(start).toHaveBeenCalledTimes(1);

  releaseStart?.({ kind: "ready" });
  expect(await first).toEqual({ kind: "ready" });
  expect(await second).toEqual({ kind: "ready" });
  expect(await owner.prewarm("C:/work", "C:/work/src/Third.java")).toEqual({ kind: "ready" });
  expect(operations.outcomes).toEqual(["succeeded"]);
  expect(operations.names).toEqual(["workspacePrewarm"]);
  expect(notifyReady).toHaveBeenCalledTimes(1);
  expect(notifyPreparing).toHaveBeenCalledTimes(1);
  expect(stop).not.toHaveBeenCalled();
});

test("closing a workspace cancels an in-flight prewarm and stops its server", async () => {
  let releaseStart: ((outcome: { kind: "ready" }) => void) | undefined;
  const start = mock(
    () =>
      new Promise<{ kind: "ready" }>((resolve) => {
        releaseStart = resolve;
      }),
  );
  const stop = mock(async () => undefined);
  const clearReady = mock(() => undefined);
  const operations = operationRecorder();
  const owner = new JavaWorkspaceLanguageServerOwner(
    { start, stop },
    operations.factory,
    () => undefined,
    clearReady,
    () => undefined,
    () => undefined,
  );

  const prewarm = owner.prewarm("C:/work", "C:/work/src/Main.java");
  const close = owner.stop("C:\\work");
  releaseStart?.({ kind: "ready" });

  expect(await prewarm).toEqual({
    kind: "cancelled",
    reason: "workspace-closed-before-ready",
  });
  await close;
  expect(operations.outcomes).toEqual(["cancelled", "succeeded"]);
  expect(operations.names).toEqual(["workspacePrewarm", "workspaceStop"]);
  expect(stop).toHaveBeenCalledTimes(1);
  expect(clearReady).toHaveBeenCalledWith("C:\\work", "java");
});

test("records a timeout without converting it to a generic failure", async () => {
  const timeout = Object.assign(new Error("JDTLS initialize timed out"), {
    code: "timed_out",
  });
  const operations = operationRecorder();
  const notifyFailure = mock(() => undefined);
  const owner = new JavaWorkspaceLanguageServerOwner(
    {
      start: async () => {
        throw timeout;
      },
      stop: async () => undefined,
    },
    operations.factory,
    () => undefined,
    () => undefined,
    () => undefined,
    notifyFailure,
  );

  expect(await owner.prewarm("C:/work", "C:/work/src/Main.java")).toEqual({
    kind: "timedOut",
    error: timeout,
  });
  expect(operations.outcomes).toEqual(["timedOut"]);
  expect(notifyFailure).toHaveBeenCalledWith(
    "C:/work",
    "java",
    { kind: "timedOut", detail: "JDTLS initialize timed out" },
    expect.any(Function),
  );
});

test("waits for a stopping owner before starting a replacement workspace session", async () => {
  const startResolvers: Array<(outcome: { kind: "ready" }) => void> = [];
  let releaseStop: (() => void) | undefined;
  const start = mock(
    () =>
      new Promise<{ kind: "ready" }>((resolve) => {
        startResolvers.push(resolve);
      }),
  );
  const stop = mock(
    () =>
      new Promise<void>((resolve) => {
        releaseStop = resolve;
      }),
  );
  const notifyReady = mock(() => undefined);
  const operations = operationRecorder();
  const owner = new JavaWorkspaceLanguageServerOwner(
    { start, stop },
    operations.factory,
    notifyReady,
    () => undefined,
    () => undefined,
    () => undefined,
  );

  const first = owner.prewarm("C:/work", "C:/work/src/First.java");
  const stopping = owner.stop("C:/work");
  startResolvers[0]?.({ kind: "ready" });
  expect(await first).toEqual({
    kind: "cancelled",
    reason: "workspace-closed-before-ready",
  });

  const replacement = owner.prewarm("C:/work", "C:/work/src/Second.java");
  await Promise.resolve();
  expect(stop).toHaveBeenCalledTimes(1);
  releaseStop?.();
  await stopping;
  await Promise.resolve();
  expect(start).toHaveBeenCalledTimes(2);
  startResolvers[1]?.({ kind: "ready" });

  expect(await replacement).toEqual({ kind: "ready" });
  expect(notifyReady).toHaveBeenCalledTimes(1);
  expect(operations.outcomes).toEqual(["cancelled", "succeeded", "succeeded"]);
});

test("creates a new operation after a failed start is retried", async () => {
  const failure = new Error("start failed");
  let attempt = 0;
  const operations = operationRecorder();
  const owner = new JavaWorkspaceLanguageServerOwner(
    {
      start: async () => {
        attempt += 1;
        if (attempt === 1) throw failure;
        return { kind: "ready" } as const;
      },
      stop: async () => undefined,
    },
    operations.factory,
    () => undefined,
    () => undefined,
    () => undefined,
    () => undefined,
  );

  expect(await owner.prewarm("C:/work", "C:/work/src/Main.java")).toEqual({
    kind: "failed",
    error: failure,
  });
  expect(await owner.prewarm("C:/work", "C:/work/src/Main.java")).toEqual({ kind: "ready" });

  expect(operations.outcomes).toEqual(["failed", "succeeded"]);
  expect(operations.operationIds).toHaveLength(2);
  expect(new Set(operations.operationIds).size).toBe(2);
});

test("reports a configured workspace without a usable runtime as unavailable", async () => {
  const operations = operationRecorder();
  const notifyFailure = mock(() => undefined);
  const owner = new JavaWorkspaceLanguageServerOwner(
    {
      start: async () => ({ kind: "notConfigured" }),
      stop: async () => undefined,
    },
    operations.factory,
    () => undefined,
    () => undefined,
    () => undefined,
    notifyFailure,
  );

  expect(await owner.prewarm("C:/work", "C:/work/src/Main.java")).toEqual({
    kind: "unavailable",
    reason: "notConfigured",
  });
  expect(operations.outcomes).toEqual(["failed"]);
  expect(notifyFailure).toHaveBeenCalledWith(
    "C:/work",
    "java",
    { kind: "unavailable" },
    expect.any(Function),
  );
});
