import { afterEach, beforeEach, expect, mock, test } from "bun:test";

type Listener = (event: { payload: unknown }) => void;
const listeners = new Map<string, Listener>();
let onConnect: () => Promise<void> = async () => {};
let relocate: () => Promise<unknown> = async () => ({ breakpoints: [], originalIndices: [] });
let respond: (args: Record<string, unknown>) => void = () => {};
const invoke = mock(async (command: string, args: Record<string, unknown>) => {
  if (command === "debug.relocateBreakpoints") return await relocate();
  if (command === "debug_connect_session") {
    await onConnect();
    return { id: "session-1", command: "tcp", cwd: "D:/work", args: [] };
  }
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
  relocate = async () => ({ breakpoints: [] });
  onConnect = async () => {};
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


test("Java attach waits for source edits and reads fresh breakpoint lines after the barrier", async () => {
  const { useDebuggerStore } = await import("../stores/debugger.store");
  const { queueBreakpointRelocation, flushBreakpointRelocations } = await import("./breakpoint-relocation");
  const previous = useDebuggerStore.getState();
  useDebuggerStore.setState({ breakpoints: [{ id: "before", filePath: "D:/work/Main.java", line: 1, enabled: true, createdAt: 1 }] });
  let release!: (value: unknown) => void;
  let entered!: () => void;
  const started = new Promise<void>(resolve => { entered = resolve; });
  const response = new Promise<unknown>(resolve => { release = resolve; });
  relocate = async () => { entered(); return await response; };
  let launch: Promise<unknown> | undefined;
  try {
    queueBreakpointRelocation("D:/work/Main.java", { previousContent: "first();\nrun();\n", content: "\nfirst();\nrun();\n", external: false,
      changes: [{ offset: 0, length: 0, text: "\n", start: { line: 0, column: 0 }, end: { line: 0, column: 0 } }] });
    await started;
    launch = startConnectedDebugLaunchSession({ id: "boot", name: "Boot", runtime: "custom", request: "attach", source: "generated" },
      4711, () => useDebuggerStore.getState().breakpoints, "D:/work");
    expect(invoke.mock.calls.map(call => call[0])).toEqual(["debug.relocateBreakpoints"]);
    release({ breakpoints: [{ line: 3, enabled: true }], originalIndices: [0] });
    await launch;
    const sent = invoke.mock.calls.find(call => call[0] === "debug_send_request" && (call[1].request as Record<string, unknown>).command === "setBreakpoints");
    expect(sent?.[1]).toMatchObject({ request: { arguments: { breakpoints: [{ line: 3 }] } } });
  } finally {
    release({ breakpoints: [], originalIndices: [] });
    if (launch) await launch;
    useDebuggerStore.getState().actions.clearBreakpoints();
    await flushBreakpointRelocations();
    useDebuggerStore.setState(previous);
  }
});


test("adapter connection cannot freeze a breakpoint snapshot before source edits finish", async () => {
  const { useDebuggerStore } = await import("../stores/debugger.store");
  const previous = useDebuggerStore.getState();
  const point = { id: "bp", filePath: "D:/work/Main.java", line: 1, enabled: true, createdAt: 1 };
  useDebuggerStore.setState({ breakpoints: [point] });
  onConnect = async () => { useDebuggerStore.setState({ breakpoints: [{ ...point, line: 4 }] }); };
  try {
    await startConnectedDebugLaunchSession({ id: "boot", name: "Boot", runtime: "custom", request: "attach", source: "generated" },
      4711, () => useDebuggerStore.getState().breakpoints, "D:/work");
    const sent = invoke.mock.calls.find(call => call[0] === "debug_send_request" && (call[1].request as Record<string, unknown>).command === "setBreakpoints");
    expect(sent?.[1]).toMatchObject({ request: { arguments: { breakpoints: [{ line: 5 }] } } });
  } finally { useDebuggerStore.setState(previous); }
});
