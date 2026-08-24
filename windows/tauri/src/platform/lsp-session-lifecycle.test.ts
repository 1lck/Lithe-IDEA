import { describe, expect, test } from "bun:test";
import {
  createSessionLifecycle,
  isSessionReady,
  isSessionTerminal,
  LspOperationLog,
  transitionSessionLifecycle,
} from "./lsp-session-lifecycle";

describe("LSP session lifecycle", () => {
  test("projects Core lifecycle without boolean combinations", () => {
    const lifecycle = createSessionLifecycle("recovering", "recover-operation");
    expect(isSessionReady(lifecycle)).toBe(false);
    expect(isSessionTerminal(lifecycle)).toBe(false);

    transitionSessionLifecycle(lifecycle, "initializing", "start-operation");
    transitionSessionLifecycle(lifecycle, "ready");
    expect(lifecycle).toEqual({ phase: "ready", operationId: "start-operation" });
    expect(isSessionReady(lifecycle)).toBe(true);

    transitionSessionLifecycle(lifecycle, "stopping", "stop-operation");
    transitionSessionLifecycle(lifecycle, "stopped");
    expect(isSessionTerminal(lifecycle)).toBe(true);
    expect(lifecycle.operationId).toBe("stop-operation");
  });

  test("emits one correlated terminal record for every operation outcome", () => {
    let now = 100;
    const records: Record<string, unknown>[] = [];
    const report = (
      _level: "debug" | "info" | "warn" | "error",
      _scope: string,
      _message: string,
      payload?: Record<string, unknown>,
    ) => {
      records.push(payload ?? {});
    };
    const outcomes = ["succeeded", "failed", "cancelled", "timedOut"] as const;

    for (const outcome of outcomes) {
      const operation = new LspOperationLog(
        "sessionTest",
        `operation-${outcome}`,
        { sessionId: "session-1" },
        report,
        () => now,
      );
      now += 25;
      if (outcome === "succeeded") operation.succeeded();
      if (outcome === "failed") operation.failed(new Error("failed"));
      if (outcome === "cancelled") operation.cancelled("superseded");
      if (outcome === "timedOut") operation.timedOut();
      operation.failed(new Error("must not emit twice"));
    }

    expect(records.map((record) => record.outcome)).toEqual([
      "started",
      "succeeded",
      "started",
      "failed",
      "started",
      "cancelled",
      "started",
      "timedOut",
    ]);
    expect(records.every((record) => typeof record.operationId === "string")).toBe(true);
    expect(records.filter((record) => record.outcome !== "started")).toEqual(
      expect.arrayContaining([expect.objectContaining({ durationMilliseconds: 25 })]),
    );
  });
});
