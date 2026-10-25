import { describe, expect, test } from "bun:test";
import {
  MAX_DIAGNOSTICS,
  MAX_LINE_BYTES,
  MAX_OUTPUT_BYTES,
  MAX_OUTPUT_LINES,
  MAX_OUTPUT_SESSIONS,
  MAX_TEST_CASES,
  MAX_RESULT_BYTES,
  MAX_FIELD_BYTES,
  useBuildOutputStore,
} from "./build-output-store";
import { buildOutputSessionId, type BuildOperationIdentity } from "./build-output-types";
import buildPlans from "../../../../../../shared/contracts/plugins/v1/fixtures/build-plans.json";
import type { BuildDiagnostic, BuildTestResults } from "./build-output-types";

/**
 * Store tests for the build output session state: operation and workspace
 * binding of late events, ordered single terminal, post-terminal decode
 * results, bounded buffers with truncation counters, stop lifecycle, and
 * isolation between two session identities. Pure state transitions with no
 * timers and no host calls.
 */

const WORKSPACE = "C:/work/output-store-fixture";

function identity(operationId: string, overrides: Partial<BuildOperationIdentity> = {}) {
  return {
    operationId,
    pluginId: "dev.lithe.fixture.build-static-file",
    buildSystemId: "cargo",
    root: ".",
    workspaceRoot: WORKSPACE,
    generation: 1,
    title: "cargo build",
    ...overrides,
  };
}

const SESSION_A = buildOutputSessionId("dev.lithe.fixture.build-static-file", "cargo", ".");
const SESSION_B = buildOutputSessionId(
  "dev.lithe.fixture.build-static-file",
  "cargo",
  "crates/app",
);

function actions() {
  return useBuildOutputStore.getState().actions;
}

function session(sessionId: string) {
  return useBuildOutputStore.getState().sessions[sessionId];
}

function diagnostic(path: string, line: number) {
  return { path, line, severity: "error" as const, message: `problem at ${path}:${line}` };
}

function testResults(
  status: "passed" | "failed" | "skipped" | "error" = "passed",
): BuildTestResults {
  return {
    tests: [
      {
        suite: "com.example.OrderTest",
        case: "refunds",
        status,
        invocations: 1,
      },
    ],
    summary: {
      total: 1,
      passed: status === "passed" ? 1 : 0,
      failed: status === "failed" ? 1 : 0,
      errors: status === "error" ? 1 : 0,
      skipped: status === "skipped" ? 1 : 0,
    },
    success: status === "passed",
  };
}

describe("build output store", () => {
  test("Core fixture diagnostics retain their canonical shape without a frontend decoder", () => {
    actions().reset();
    const run = identity("fixture");
    actions().beginOperation(SESSION_A, run);
    const decoded = buildPlans.cases.find((row) => row.name === "cargo short diagnostics")!.expected
      .diagnostics as BuildDiagnostic[];
    actions().applyDiagnostics(SESSION_A, run, decoded);
    expect(session(SESSION_A)!.diagnostics).toEqual(decoded);
  });

  test("all event identity fields, including plugin, instance and generation, must match", () => {
    actions().reset();
    const run = identity("same-operation");
    actions().beginOperation(SESSION_A, run);
    for (const changed of [
      { pluginId: "other.plugin" },
      { buildSystemId: "other" },
      { root: "other" },
      { generation: 2 },
    ]) {
      const stale = { ...run, ...changed };
      actions().appendChunk(SESSION_A, stale, "stderr", "foreign\n");
      actions().applyDiagnostics(SESSION_A, stale, [diagnostic("src/main.rs", 1)]);
      actions().applyTestResults(SESSION_A, stale, testResults());
      actions().complete(SESSION_A, stale, { kind: "failed" });
    }
    expect(session(SESSION_A)!.lines).toEqual([]);
    expect(session(SESSION_A)!.diagnostics).toEqual([]);
    expect(session(SESSION_A)!.testResults).toBeNull();
    expect(session(SESSION_A)!.status).toBe("running");
    actions().invalidateGeneration(2);
    expect(session(SESSION_A)).toBeUndefined();
  });

  test("multibyte unfinished lines stay bounded across fragments and expose clipping", () => {
    actions().reset();
    const run = identity("utf8");
    actions().beginOperation(SESSION_A, run);
    const encoder = new TextEncoder();
    for (let index = 0; index < 30; index += 1)
      actions().appendChunk(SESSION_A, run, "stderr", "中😀".repeat(1000));
    let state = session(SESSION_A)!;
    expect(state.lines).toHaveLength(1);
    expect(state.lines[0]!.clipped).toBe(true);
    expect(encoder.encode(state.lines[0]!.text).byteLength).toBeLessThanOrEqual(MAX_LINE_BYTES);
    expect(state.totalBytes).toBe(encoder.encode(state.lines[0]!.text).byteLength + 1);
    expect(state.lines[0]!.text).not.toContain("�");
    actions().appendChunk(SESSION_A, run, "stderr", "\nnext\r");
    actions().appendChunk(SESSION_A, run, "stderr", "\n");
    state = session(SESSION_A)!;
    expect(state.lines[1]!.text).toBe("next");
    actions().appendChunk(SESSION_A, run, "stdout", "\ud83d");
    actions().appendChunk(SESSION_A, run, "stdout", "\ude00\n");
    expect(session(SESSION_A)!.lines[session(SESSION_A)!.lines.length - 1]!.text).toBe("😀");
  });

  test("UTF-8 session budget counts multibyte rows and empty lines", () => {
    actions().reset();
    const run = identity("utf8-budget");
    actions().beginOperation(SESSION_A, run);
    actions().appendChunk(SESSION_A, run, "stdout", ("界".repeat(600) + "\n").repeat(350));
    const state = session(SESSION_A)!;
    expect(state.totalBytes).toBeLessThanOrEqual(MAX_OUTPUT_BYTES);
    expect(state.droppedLines).toBeGreaterThan(0);
    expect(state.totalBytes).toBe(
      state.lines.reduce((sum, row) => sum + new TextEncoder().encode(row.text).byteLength + 1, 0),
    );
  });

  test("decoded detail count and text budgets preserve the authoritative test summary", () => {
    actions().reset();
    const run = identity("results-budget");
    actions().beginOperation(SESSION_A, run);
    const results = testResults("skipped");
    results.tests = Array.from({ length: MAX_TEST_CASES + 11 }, () => ({ ...results.tests[0]! }));
    actions().applyTestResults(SESSION_A, run, results);
    expect(session(SESSION_A)!.testResults!.tests).toHaveLength(MAX_TEST_CASES);
    expect(session(SESSION_A)!.testsDropped).toBe(11);
    const message = "界😀".repeat(MAX_FIELD_BYTES);
    actions().applyDiagnostics(
      SESSION_A,
      run,
      Array.from({ length: MAX_DIAGNOSTICS }, () => ({ ...diagnostic("src/main.rs", 1), message })),
    );
    const state = session(SESSION_A)!;
    expect(state.diagnosticsDropped).toBeGreaterThan(0);
    expect(
      new TextEncoder().encode(JSON.stringify(state.diagnostics)).byteLength,
    ).toBeLessThanOrEqual(MAX_RESULT_BYTES + 2);
    expect(new TextEncoder().encode(state.diagnostics[0]!.message).byteLength).toBeLessThanOrEqual(
      MAX_FIELD_BYTES,
    );
    expect(state.diagnostics[0]!.message.endsWith("…")).toBe(true);
    expect(state.testResults!.summary).toEqual(results.summary);
    expect(state.testResults!.success).toBe(results.success);
    results.tests = results.tests.map((test) => ({ ...test, message }));
    actions().applyTestResults(SESSION_A, run, results);
    expect(session(SESSION_A)!.testsDropped).toBeGreaterThan(11);
    expect(
      new TextEncoder().encode(JSON.stringify(session(SESSION_A)!.testResults!.tests)).byteLength,
    ).toBeLessThanOrEqual(MAX_RESULT_BYTES + 2);
    expect(session(SESSION_A)!.testResults!.summary).toEqual(results.summary);
  });

  test("session limits refuse excess live runs and evict only finished output", () => {
    actions().reset();
    for (let index = 0; index < MAX_OUTPUT_SESSIONS; index += 1)
      expect(actions().beginOperation(`session-${index}`, identity(`op-${index}`))).toBe(true);
    expect(actions().beginOperation("overflow", identity("overflow"))).toBe(false);
    actions().complete("session-0", identity("op-0"), { kind: "succeeded" });
    expect(actions().beginOperation("overflow", identity("overflow"))).toBe(true);
    expect(Object.keys(useBuildOutputStore.getState().sessions)).toHaveLength(MAX_OUTPUT_SESSIONS);
    expect(session("session-0")).toBeUndefined();
    expect(session("session-1")!.status).toBe("running");
  });

  test("old cancellation failure cannot change a replacing operation", () => {
    actions().reset();
    const old = identity("old");
    const fresh = identity("new");
    actions().beginOperation(SESSION_A, old);
    actions().beginStop(SESSION_A, old);
    actions().beginOperation(SESSION_A, fresh);
    actions().beginStop(SESSION_A, fresh);
    actions().stopFailed(SESSION_A, old, "late failure");
    expect(session(SESSION_A)!.cancelling).toBe(true);
    expect(session(SESSION_A)!.cancelError).toBeNull();
    actions().clear(SESSION_A);
    actions().applyDiagnostics(SESSION_A, fresh, [diagnostic("src/main.rs", 1)]);
    actions().applyTestResults(SESSION_A, fresh, testResults());
    actions().complete(SESSION_A, fresh, { kind: "cancelled" });
    expect(session(SESSION_A)).toBeUndefined();
  });
  test("chunks of both streams land in arrival order and show bounded partial lines immediately", () => {
    actions().reset();
    actions().beginOperation(SESSION_A, identity("op-1"));
    const ref = identity("op-1");

    actions().appendChunk(SESSION_A, ref, "stdout", "Compiling app");
    actions().appendChunk(SESSION_A, ref, "stderr", "warning: unused import\n");
    actions().appendChunk(SESSION_A, ref, "stdout", " v0.1.0\nDone\n");

    const state = session(SESSION_A)!;
    // A stream switch ends the visible fragment so arrival order is preserved.
    expect(state.lines.map((line) => `${line.stream}:${line.text}`)).toEqual([
      "stdout:Compiling app",
      "stderr:warning: unused import",
      "stdout: v0.1.0",
      "stdout:Done",
    ]);
    expect(state.openLine).toBe(false);
    expect(session(SESSION_A)!.status).toBe("running");
  });

  test("the terminal applies once, flushes partial lines, and drops later duplicates", () => {
    actions().reset();
    actions().beginOperation(SESSION_A, identity("op-1"));
    const ref = identity("op-1");
    actions().appendChunk(SESSION_A, ref, "stdout", "partial tail");

    actions().complete(SESSION_A, ref, { kind: "failed", exitCode: 1, message: "compile error" });
    actions().complete(SESSION_A, ref, { kind: "succeeded" });
    actions().appendChunk(SESSION_A, ref, "stdout", "late chunk\n");

    const state = session(SESSION_A)!;
    expect(state.status).toBe("failed");
    expect(state.terminal).toEqual({ kind: "failed", exitCode: 1, message: "compile error" });
    expect(state.lines.map((line) => line.text)).toEqual(["partial tail"]);
  });

  test("events of an older operation never reach the current one", () => {
    actions().reset();
    actions().beginOperation(SESSION_A, identity("op-1"));
    actions().beginOperation(SESSION_A, identity("op-2"));
    const stale = identity("op-1");
    const fresh = identity("op-2");

    actions().appendChunk(SESSION_A, stale, "stdout", "stale stdout\n");
    actions().appendChunk(SESSION_A, fresh, "stdout", "fresh stdout\n");
    actions().complete(SESSION_A, stale, { kind: "failed", message: "late failure" });
    actions().applyDiagnostics(SESSION_A, stale, [diagnostic("src/main.rs", 4)]);
    actions().applyTestResults(SESSION_A, stale, testResults("failed"));

    const state = session(SESSION_A)!;
    expect(state.identity.operationId).toBe("op-2");
    expect(state.lines.map((line) => line.text)).toEqual(["fresh stdout"]);
    expect(state.status).toBe("running");
    expect(state.diagnostics).toEqual([]);
    expect(state.testResults).toBeNull();
  });

  test("events of another workspace root are dropped", () => {
    actions().reset();
    actions().beginOperation(SESSION_A, identity("op-1"));
    const foreign = identity("op-1", { workspaceRoot: "C:/work/elsewhere" });

    actions().appendChunk(SESSION_A, foreign, "stdout", "other workspace\n");
    actions().complete(SESSION_A, foreign, { kind: "succeeded" });

    const state = session(SESSION_A)!;
    expect(state.lines).toEqual([]);
    expect(state.status).toBe("running");
  });

  test("decoded diagnostics and test results attach after the terminal of the same operation", () => {
    actions().reset();
    actions().beginOperation(SESSION_A, identity("op-1"));
    const ref = identity("op-1");
    actions().complete(SESSION_A, ref, { kind: "failed", exitCode: 1, message: "tests failed" });

    actions().applyDiagnostics(SESSION_A, ref, [diagnostic("app/src/Order.java", 12)]);
    actions().applyTestResults(SESSION_A, ref, testResults("failed"));

    const state = session(SESSION_A)!;
    expect(state.diagnostics).toEqual([diagnostic("app/src/Order.java", 12)]);
    expect(state.testResults?.success).toBe(false);
    expect(state.testResults?.summary.failed).toBe(1);
  });

  test("a run that never started keeps decode results out", () => {
    actions().reset();
    actions().beginOperation(SESSION_A, identity("op-1"));
    const ref = identity("op-1");
    actions().complete(SESSION_A, ref, { kind: "failedToStart", message: "tool missing" });

    actions().applyDiagnostics(SESSION_A, ref, [diagnostic("src/main.rs", 1)]);
    actions().applyTestResults(SESSION_A, ref, testResults());

    const state = session(SESSION_A)!;
    expect(state.status).toBe("failedToStart");
    expect(state.diagnostics).toEqual([]);
    expect(state.testResults).toBeNull();
  });

  test("the line budget evicts the oldest lines and counts them for the notice", () => {
    actions().reset();
    actions().beginOperation(SESSION_A, identity("op-1"));
    const ref = identity("op-1");

    for (let index = 0; index < MAX_OUTPUT_LINES + 25; index += 1) {
      actions().appendChunk(SESSION_A, ref, "stdout", `line ${index}\n`);
    }

    const state = session(SESSION_A)!;
    expect(state.lines).toHaveLength(MAX_OUTPUT_LINES);
    expect(state.droppedLines).toBe(25);
    expect(state.lines[0]!.text).toBe("line 25");
    expect(state.lines[state.lines.length - 1]!.text).toBe(`line ${MAX_OUTPUT_LINES + 24}`);
  });

  test("the byte budget evicts lines even below the line cap", () => {
    actions().reset();
    actions().beginOperation(SESSION_A, identity("op-1"));
    const ref = identity("op-1");
    const filler = "x".repeat(1000);

    let sent = 0;
    while (sent <= MAX_OUTPUT_BYTES + 5000) {
      actions().appendChunk(SESSION_A, ref, "stdout", `${filler}\n`);
      sent += filler.length;
    }

    const state = session(SESSION_A)!;
    expect(state.lines.length).toBeLessThanOrEqual(MAX_OUTPUT_LINES);
    expect(state.totalBytes).toBeLessThanOrEqual(MAX_OUTPUT_BYTES);
    expect(state.droppedLines).toBeGreaterThan(0);
  });

  test("one oversized line is clipped and marked instead of breaking the budget", () => {
    actions().reset();
    actions().beginOperation(SESSION_A, identity("op-1"));
    const ref = identity("op-1");

    actions().appendChunk(SESSION_A, ref, "stdout", `${"y".repeat(MAX_LINE_BYTES * 3)}\n`);

    const line = session(SESSION_A)!.lines[0]!;
    expect(line.text).toHaveLength(MAX_LINE_BYTES);
    expect(line.clipped).toBe(true);
  });

  test("diagnostics beyond the session cap are dropped with a counter", () => {
    actions().reset();
    actions().beginOperation(SESSION_A, identity("op-1"));
    const ref = identity("op-1");
    const many = Array.from({ length: MAX_DIAGNOSTICS + 7 }, (_, index) =>
      diagnostic(`src/File${index}.rs`, index + 1),
    );

    actions().applyDiagnostics(SESSION_A, ref, many);

    const state = session(SESSION_A)!;
    expect(state.diagnostics).toHaveLength(MAX_DIAGNOSTICS);
    expect(state.diagnosticsDropped).toBe(7);
  });

  test("beginStop and stopFailed drive the stop control; a terminal clears the stop state", () => {
    actions().reset();
    actions().beginOperation(SESSION_A, identity("op-1"));
    const ref = identity("op-1");

    actions().beginStop(SESSION_A, ref);
    actions().stopFailed(SESSION_A, ref, "port refused");
    expect(session(SESSION_A)!.cancelling).toBe(false);
    expect(session(SESSION_A)!.cancelError).toBe("port refused");
    expect(session(SESSION_A)!.status).toBe("running");

    actions().beginStop(SESSION_A, ref);
    actions().complete(SESSION_A, ref, { kind: "cancelled" });
    const finished = session(SESSION_A)!;
    expect(finished.status).toBe("cancelled");
    expect(finished.cancelling).toBe(false);
    expect(finished.cancelError).toBeNull();
  });

  test("stop transitions are ignored once the run already ended", () => {
    actions().reset();
    actions().beginOperation(SESSION_A, identity("op-1"));
    const ref = identity("op-1");
    actions().complete(SESSION_A, ref, { kind: "succeeded" });

    actions().beginStop(SESSION_A, ref);
    actions().stopFailed(SESSION_A, ref, "late stop failure");

    const state = session(SESSION_A)!;
    expect(state.status).toBe("succeeded");
    expect(state.cancelError).toBeNull();
  });

  test("two session identities hold independent operations", () => {
    actions().reset();
    actions().beginOperation(SESSION_A, identity("op-a"));
    actions().beginOperation(SESSION_B, identity("op-b", { root: "crates/app" }));
    const refA = identity("op-a");
    const refB = identity("op-b", { root: "crates/app" });

    actions().appendChunk(SESSION_A, refA, "stdout", "root output\n");
    actions().appendChunk(SESSION_B, refB, "stdout", "nested output\n");
    actions().complete(SESSION_B, refB, { kind: "succeeded" });

    expect(session(SESSION_A)!.status).toBe("running");
    expect(session(SESSION_A)!.lines.map((line) => line.text)).toEqual(["root output"]);
    expect(session(SESSION_B)!.status).toBe("succeeded");
    expect(session(SESSION_B)!.lines.map((line) => line.text)).toEqual(["nested output"]);
  });

  test("clear drops one session and reset drops all sessions", () => {
    actions().reset();
    actions().beginOperation(SESSION_A, identity("op-a"));
    actions().beginOperation(SESSION_B, identity("op-b", { root: "crates/app" }));

    actions().clear(SESSION_A);
    expect(session(SESSION_A)).toBeUndefined();
    expect(session(SESSION_B)).toBeDefined();

    actions().reset();
    expect(useBuildOutputStore.getState().sessions).toEqual({});
  });
});
