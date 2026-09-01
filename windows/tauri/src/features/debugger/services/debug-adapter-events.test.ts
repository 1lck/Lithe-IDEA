import { beforeEach, expect, mock, test } from "bun:test";
import type { DebugProtocolMessage } from "../types/debugger.types";

let operationCounter = 0;
const sendDebugAdapterRequest = mock(
  async (): Promise<{ sessionId: string; operationId: string }> => {
    operationCounter += 1;
    return { sessionId: "session-1", operationId: `debug-op-${operationCounter}` };
  },
);
const subscribeDebuggerEvents = mock(async () => () => {});

type DebuggerEventHandlers = {
  onMessage?: (payload: DebugProtocolMessage) => void;
  onOutput?: (payload: unknown) => void;
  onSessionEnded?: (payload: unknown) => void;
};

let capturedHandlers: DebuggerEventHandlers = {};

mock.module("@/features/debugger/services/debug-adapter-service", () => ({
  sendDebugAdapterRequest,
  subscribeDebuggerEvents: async (handlers: DebuggerEventHandlers) => {
    capturedHandlers = handlers;
    return () => {};
  },
}));

const { initializeDebuggerEventBridge } = await import("./debug-adapter-events");
const { useDebuggerStore } = await import("../stores/debugger.store");

const flush = async () => {
  await new Promise((resolve) => setTimeout(resolve, 0));
  await new Promise((resolve) => setTimeout(resolve, 0));
};

const emitMessage = (sessionId: string, message: unknown) => {
  capturedHandlers.onMessage?.({ sessionId, message });
};

beforeEach(() => {
  operationCounter = 0;
  sendDebugAdapterRequest.mockClear();
  useDebuggerStore.setState({
    pendingRequests: {},
    threads: [],
    stackFrames: [],
    scopes: [],
    variablesByReference: {},
    watchResults: {},
    adapterOutput: [],
    stoppedState: null,
    activeSession: null,
  });
});

test("stopped events pause the session and cascade into stack trace requests", async () => {
  await initializeDebuggerEventBridge();
  useDebuggerStore.getState().actions.startSession({
    id: "session-1",
    name: "Demo",
    configId: "generated-bun",
    command: "bun",
    startedAt: 1,
    status: "running",
  });

  emitMessage("session-1", { type: "stopped", reason: "breakpoint", threadId: 3 });
  await flush();

  const state = useDebuggerStore.getState();
  expect(state.activeSession?.status).toBe("paused");
  expect(state.stoppedState).toEqual({
    reason: "breakpoint",
    threadId: 3,
    description: undefined,
  });
  expect(sendDebugAdapterRequest).toHaveBeenCalledWith("session-1", "stackTrace", {
    threadId: 3,
  });
  expect(state.pendingRequests["debug-op-1"]).toEqual({
    command: "stackTrace",
    threadId: 3,
  });
});

test("normalized thread results fill the thread list and cascade further", async () => {
  await initializeDebuggerEventBridge();
  useDebuggerStore.getState().actions.registerAdapterRequest("threads-op", {
    command: "threads",
  });

  emitMessage("session-1", {
    type: "operationCompleted",
    operationId: "threads-op",
    result: { kind: "threads", threads: [{ id: 1, name: "main" }] },
  });
  await flush();

  const state = useDebuggerStore.getState();
  expect(state.threads).toEqual([{ id: 1, name: "main" }]);
  expect(state.pendingRequests["threads-op"]).toBeUndefined();
  expect(sendDebugAdapterRequest).toHaveBeenCalledWith("session-1", "stackTrace", {
    threadId: 1,
  });
  expect(state.pendingRequests["debug-op-1"]).toEqual({
    command: "stackTrace",
    threadId: 1,
  });
});

test("evaluate results land in watch results for the correlated expression", async () => {
  await initializeDebuggerEventBridge();
  useDebuggerStore.getState().actions.registerAdapterRequest("debug-op-1", {
    command: "evaluate",
    expressionId: "watch-1",
  });

  emitMessage("session-1", {
    type: "operationCompleted",
    operationId: "debug-op-1",
    result: {
      kind: "evaluate",
      variable: { name: "", value: "42", type: "number", variablesReference: 0 },
    },
  });
  await flush();

  const result = useDebuggerStore.getState().watchResults["watch-1"];
  expect(result?.value).toBe("42");
  expect(result?.type).toBe("number");
  expect(result?.error).toBeUndefined();
});

test("failed evaluate operations surface an actionable watch error", async () => {
  await initializeDebuggerEventBridge();
  useDebuggerStore.getState().actions.registerAdapterRequest("debug-op-1", {
    command: "evaluate",
    expressionId: "watch-2",
  });

  emitMessage("session-1", {
    type: "operationFailed",
    operationId: "debug-op-1",
    command: "evaluate",
    code: "adapterRejected",
    message: "Expression could not be evaluated.",
  });
  await flush();

  const result = useDebuggerStore.getState().watchResults["watch-2"];
  expect(result?.error).toBe("Expression could not be evaluated.");
  expect(useDebuggerStore.getState().pendingRequests).toEqual({});
});

test("normalized output events reach the debug console", async () => {
  await initializeDebuggerEventBridge();

  emitMessage("session-1", { type: "output", category: "stderr", output: "boom" });
  await flush();

  expect(useDebuggerStore.getState().adapterOutput).toEqual([
    { sessionId: "session-1", stream: "stderr", data: "boom" },
  ]);
});

test("terminated events end only the matching session", async () => {
  await initializeDebuggerEventBridge();
  useDebuggerStore.getState().actions.startSession({
    id: "session-1",
    name: "Demo",
    configId: "generated-bun",
    command: "bun",
    startedAt: 1,
    status: "running",
  });

  emitMessage("session-1", { type: "terminated", exitCode: 0 });
  await flush();

  expect(useDebuggerStore.getState().activeSession?.status).toBe("idle");
});
