import { describe, expect, test } from "bun:test";
import {
  sanitizeFrontendLogPayload,
  serializeConsoleArguments,
  setFrontendDiagnosticEnabled,
  setFrontendLogTransportForTests,
  setFrontendLogWorkspaceRoots,
  submitFrontendLog,
  subscribeFrontendDiagnosticEnabled,
} from "./frontend-log-runtime";

describe("frontend log serialization", () => {
  test("never throws for circular objects", () => {
    const value: Record<string, unknown> = { message: "failure" };
    value.self = value;
    expect(() => serializeConsoleArguments([value])).not.toThrow();
    expect(serializeConsoleArguments([value])).toContain("[circular]");
  });

  test("summarizes errors and limits stack frames", () => {
    const error = new Error("broken");
    error.stack = [
      "Error: broken",
      ...Array.from({ length: 20 }, (_, index) => `at frame${index}`),
    ].join("\n");
    const serialized = serializeConsoleArguments([error]);
    expect(serialized).toContain("Error: broken");
    expect(serialized).toContain("frame7");
    expect(serialized).not.toContain("frame12");
  });

  test("bounds array traversal before serializing the result", () => {
    let visited = 0;
    const values = Array.from({ length: 1000 }, () => ({
      get value() {
        visited += 1;
        return "item";
      },
    }));
    serializeConsoleArguments([values]);
    expect(visited).toBe(24);
  });

  test("truncates oversized payloads", () => {
    const serialized = serializeConsoleArguments(["x".repeat(5_000)]);
    expect(serialized.length).toBeLessThanOrEqual(3_000);
    expect(serialized).toContain("[truncated]");
  });

  test("relativizes registered workspace paths and shortens outside paths", () => {
    setFrontendLogWorkspaceRoots(["D:/work/project"]);
    expect(
      sanitizeFrontendLogPayload({
        filePath: "D:\\work\\project\\src\\main.ts",
        workspaceFolders: ["D:\\work\\project", "C:\\outside\\two"],
        root: "C:\\Users\\person\\outside.txt",
      }),
    ).toEqual({
      filePath: "<workspace>/src/main.ts",
      workspaceFolders: ["<workspace>", "two"],
      root: "outside.txt",
    });
  });

  test("notifies subscribers when diagnostic logging changes", () => {
    const changes: boolean[] = [];
    const initial = false;
    setFrontendDiagnosticEnabled(initial);
    const unsubscribe = subscribeFrontendDiagnosticEnabled((enabled) => changes.push(enabled));

    setFrontendDiagnosticEnabled(true);
    setFrontendDiagnosticEnabled(false);
    unsubscribe();

    expect(changes).toEqual([initial, true, false]);
  });
});

describe("frontend log forwarding", () => {
  // Runs each scheduled flush on demand so batching never depends on real timers.
  function manualTransport(onBatch: (messages: string[]) => Promise<void>) {
    const scheduled: Array<() => void> = [];
    const restore = setFrontendLogTransportForTests(
      (entries) => onBatch(entries.map((entry) => entry.message)),
      (run) => scheduled.push(run),
    );
    const flush = async () => {
      // Flushing settles the batch promise, whose handlers may schedule the next flush.
      for (let round = 0; round < 3 && scheduled.length > 0; round++) {
        scheduled.splice(0).forEach((run) => run());
        for (let turn = 0; turn < 5; turn++) await Promise.resolve();
      }
    };
    return { flush, restore };
  }

  test("sends logs submitted together in one batch", async () => {
    const batches: string[][] = [];
    const transport = manualTransport(async (messages) => {
      batches.push(messages);
    });
    try {
      const results = Promise.all([
        submitFrontendLog({ level: "info", scope: "test", message: "first" }),
        submitFrontendLog({ level: "warn", scope: "test", message: "second" }),
      ]);
      await transport.flush();
      expect(await results).toEqual([true, true]);
      expect(batches).toEqual([["first", "second"]]);
    } finally {
      transport.restore();
    }
  });

  test("reports failed batches and announces recovery in a later batch", async () => {
    const batches: string[][] = [];
    let fail = true;
    const transport = manualTransport(async (messages) => {
      batches.push(messages);
      if (fail) throw new Error("transport down");
    });
    try {
      const lost = submitFrontendLog({ level: "error", scope: "test", message: "lost" });
      await transport.flush();
      expect(await lost).toBe(false);

      fail = false;
      const kept = submitFrontendLog({ level: "error", scope: "test", message: "kept" });
      await transport.flush();
      expect(await kept).toBe(true);
      expect(batches).toEqual([["lost"], ["kept"], ["frontend log forwarding recovered"]]);
    } finally {
      transport.restore();
    }
  });

  test("drops debug logs while diagnostics are off without sending anything", async () => {
    let sent = 0;
    const transport = manualTransport(async () => {
      sent += 1;
    });
    try {
      setFrontendDiagnosticEnabled(false);
      expect(await submitFrontendLog({ level: "debug", scope: "test", message: "noise" })).toBe(
        false,
      );
      await transport.flush();
      expect(sent).toBe(0);
    } finally {
      transport.restore();
    }
  });
});
