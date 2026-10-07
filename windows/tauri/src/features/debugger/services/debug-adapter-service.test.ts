import { afterEach, beforeEach, expect, mock, test } from "bun:test";

type Listener = (event: { payload: unknown }) => void;
const listeners = new Map<string, Listener>();
let respond: (args: Record<string, unknown>) => void = () => {};
const invoke = mock(async (command: string, args: Record<string, unknown>) => {
  if (command === "debug_connect_session")
    return { id: "session-1", command: "tcp", cwd: "D:/work", args: [] };
  if (command !== "debug_send_request") return undefined;
  // Mirror the real Tauri signature: debug_send_request(app, request: DebugSendRequest).
  const request = args.request as Record<string, unknown> | undefined;
  if (!request) throw new Error("debug_send_request missing required key request");
  respond(request);
  return { sessionId: request.sessionId, operationId: request.operationId };
});
mock.module("@/platform/tauri-core", () => ({ invoke }));
mock.module("@tauri-apps/api/event", () => ({
  listen: async (name: string, listener: Listener) => {
    listeners.set(name, listener);
    return () => {
      listeners.delete(name);
    };
  },
}));
const { applyJavaCodeChanges, startConnectedDebugLaunchSession } =
  await import("./debug-adapter-service");

beforeEach(() => {
  listeners.clear();
  invoke.mockClear();
  respond = () => {};
});
afterEach(() => {
  listeners.clear();
});

function emit(sessionId: unknown, message: unknown) {
  listeners.get("debugger_message")?.({ payload: { sessionId, message } });
}

test("hot replacement waits for its result, ignores unrelated results and removes listeners", async () => {
  respond = (args) => {
    emit("other-session", { type: "operationFailed", operationId: args.operationId });
    emit(args.sessionId, { type: "operationFailed", operationId: "other-operation" });
    emit(args.sessionId, {
      type: "operationCompleted",
      operationId: args.operationId,
      result: { kind: "redefineClasses", changedClasses: ["example.Main"] },
    });
  };
  expect(await applyJavaCodeChanges("session-1")).toEqual(["example.Main"]);
  expect((invoke.mock.calls[0]?.[1].request as Record<string, unknown>).command).toBe(
    "redefineClasses",
  );
  expect(listeners.size).toBe(0);
});

test("adapter rejection reports the JVM reason and removes listeners", async () => {
  respond = (args) =>
    emit(args.sessionId, {
      type: "operationFailed",
      operationId: args.operationId,
      message: "Schema change unsupported",
    });
  await expect(applyJavaCodeChanges("session-1")).rejects.toThrow("Schema change unsupported");
  expect(listeners.size).toBe(0);
});

test("host send rejection settles the operation and removes listeners", async () => {
  respond = () => {
    throw new Error("Transport closed");
  };
  await expect(applyJavaCodeChanges("session-1")).rejects.toThrow("Transport closed");
  expect(listeners.size).toBe(0);
});

test("session termination retires an update before a replacement session can receive it", async () => {
  respond = (args) => {
    listeners.get("debugger_session_ended")?.({ payload: { sessionId: args.sessionId } });
  };
  await expect(applyJavaCodeChanges("session-1")).rejects.toThrow("debug session ended");
  expect(listeners.size).toBe(0);
});

test("the real native request envelope queues breakpoints before Java attach and session-ready", async () => {
  await startConnectedDebugLaunchSession(
    {
      id: "boot",
      name: "Boot",
      runtime: "custom",
      type: "java",
      request: "attach",
      source: "generated",
      launchArguments: { hostName: "127.0.0.1", port: 5005 },
    },
    4711,
    [{ id: "bp", filePath: "D:/work/Main.java", line: 8, enabled: true, createdAt: 1 }],
    "D:/work",
  );
  expect(
    invoke.mock.calls.map(([command, args]) =>
      command === "debug_send_request"
        ? (args.request as Record<string, unknown>).command
        : command,
    ),
  ).toEqual(["debug_connect_session", "setBreakpoints", "attach", "debug_session_ready"]);
  expect(invoke.mock.calls[1]?.[1]).toEqual({
    request: {
      sessionId: "session-1",
      command: "setBreakpoints",
      arguments: { source: { path: "D:/work/Main.java" }, breakpoints: [{ line: 9 }] },
      operationId: undefined,
    },
  });
});
