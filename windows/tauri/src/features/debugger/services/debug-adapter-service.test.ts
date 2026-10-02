import { afterEach, beforeEach, expect, mock, test } from "bun:test";

type Listener = (event: { payload: unknown }) => void;
const listeners = new Map<string, Listener>();
let respond: (args: Record<string, unknown>) => void = () => {};
const invoke = mock(async (_command: string, args: Record<string, unknown>) => {
  respond(args);
  return { sessionId: args.sessionId, operationId: args.operationId };
});
mock.module("@/platform/tauri-core", () => ({ invoke }));
mock.module("@tauri-apps/api/event", () => ({
  listen: async (name: string, listener: Listener) => {
    listeners.set(name, listener);
    return () => { listeners.delete(name); };
  },
}));
const { applyJavaCodeChanges } = await import("./debug-adapter-service");

beforeEach(() => {
  listeners.clear();
  invoke.mockClear();
});
afterEach(() => { listeners.clear(); });

function emit(sessionId: unknown, message: unknown) {
  listeners.get("debugger_message")?.({ payload: { sessionId, message } });
}

test("hot replacement waits for its result, ignores unrelated results and removes listeners", async () => {
  respond = (args) => {
    emit("other-session", { type: "operationFailed", operationId: args.operationId });
    emit(args.sessionId, { type: "operationFailed", operationId: "other-operation" });
    emit(args.sessionId, {
      type: "operationCompleted", operationId: args.operationId,
      result: { kind: "redefineClasses", changedClasses: ["example.Main"] },
    });
  };
  expect(await applyJavaCodeChanges("session-1")).toEqual(["example.Main"]);
  expect(invoke.mock.calls[0]?.[1].command).toBe("redefineClasses");
  expect(listeners.size).toBe(0);
});

test("adapter rejection reports the JVM reason and removes listeners", async () => {
  respond = (args) => emit(args.sessionId, {
    type: "operationFailed", operationId: args.operationId, message: "Schema change unsupported",
  });
  await expect(applyJavaCodeChanges("session-1")).rejects.toThrow("Schema change unsupported");
  expect(listeners.size).toBe(0);
});

test("host send rejection settles the operation and removes listeners", async () => {
  respond = () => { throw new Error("Transport closed"); };
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
