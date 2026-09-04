import { beforeEach, expect, mock, test } from "bun:test";
import type { DebugProtocolMessage, DebugSessionEnded } from "../types/debugger.types";

let operationCounter = 0;
let debugOperationCounter = 0;
const sendDebugAdapterRequest = mock(
  async (
    _sessionId: string,
    _command: string,
    _argumentsPayload?: unknown,
    requestedOperationId?: string,
  ): Promise<{ sessionId: string; operationId: string }> => {
    operationCounter += 1;
    return {
      sessionId: "session-1",
      operationId: requestedOperationId ?? `adapter-op-${operationCounter}`,
    };
  },
);
const stopDebugAdapterSession = mock(async (_sessionId: string): Promise<void> => {});
const subscribeDebuggerEvents = mock(async () => () => {});

type DebuggerEventHandlers = {
  onMessage?: (payload: DebugProtocolMessage) => void | Promise<void>;
  onOutput?: (payload: unknown) => void;
  onSessionEnded?: (payload: DebugSessionEnded) => void;
};

let capturedHandlers: DebuggerEventHandlers = {};

mock.module("@/features/debugger/services/debug-adapter-service", () => ({
  createDebugOperationId: () => `ui-debug-op-${++debugOperationCounter}`,
  sendDebugAdapterRequest,
  stopDebugAdapterSession,
  subscribeDebuggerEvents: async (handlers: DebuggerEventHandlers) => {
    capturedHandlers = handlers;
    return () => {};
  },
}));

const { initializeDebuggerEventBridge, selectDebugThread } = await import(
  "./debug-adapter-events"
);
const { useDebuggerStore } = await import("../stores/debugger.store");

// The bridge returns the awaited event-handling promise, so tests await the
// full cascade without real timers (write-stable-tests gate).
const emitMessage = (sessionId: string, message: unknown) =>
  capturedHandlers.onMessage?.({ sessionId, message });

const getRequestOperationId = (callIndex: number): string => {
  const operationId = sendDebugAdapterRequest.mock.calls[callIndex]?.[3];
  if (typeof operationId !== "string") {
    throw new Error(`Request ${callIndex} did not include an operation ID.`);
  }
  return operationId;
};

beforeEach(() => {
  operationCounter = 0;
  debugOperationCounter = 0;
  sendDebugAdapterRequest.mockClear();
  stopDebugAdapterSession.mockClear();
  useDebuggerStore.setState({
    pendingRequests: {},
    threads: [],
    stackFrames: [],
    selectedFrameId: null,
    scopes: [],
    variablesByReference: {},
    watchResults: {},
    adapterOutput: [],
    endedSessions: [],
    stoppedState: null,
    activeSession: null,
  });
});

const startSession = (id: string) => {
  useDebuggerStore.getState().actions.startSession({
    id,
    name: "Demo",
    configId: "generated-bun",
    command: "bun",
    startedAt: 1,
    status: "running",
  });
};

test("stopped events pause the session and cascade into stack trace requests", async () => {
  await initializeDebuggerEventBridge();
  startSession("session-1");

  await emitMessage("session-1", { type: "stopped", reason: "breakpoint", threadId: 3 });

  const state = useDebuggerStore.getState();
  expect(state.activeSession?.status).toBe("paused");
  expect(state.stoppedState).toEqual({
    reason: "breakpoint",
    threadId: 3,
    description: undefined,
  });
  expect(sendDebugAdapterRequest).toHaveBeenCalledWith("session-1", "stackTrace", {
    threadId: 3,
  }, getRequestOperationId(0));
  expect(state.pendingRequests[getRequestOperationId(0)]).toEqual({
    command: "stackTrace",
    threadId: 3,
  });
});

test("selecting another thread clears stale inspection data and ignores its late response", async () => {
  await initializeDebuggerEventBridge();
  startSession("session-1");
  await emitMessage("session-1", { type: "stopped", reason: "breakpoint", threadId: 1 });

  const oldStackOperationId = getRequestOperationId(0);
  const actions = useDebuggerStore.getState().actions;
  actions.setStackFrames([{ id: 11, name: "old", line: 1, column: 1 }]);
  actions.setScopes([{ name: "Locals", variablesReference: 10 }]);
  actions.setVariables(10, [{ name: "old", value: "1", variablesReference: 0 }]);

  await selectDebugThread("session-1", 2);

  const selectedStackOperationId = getRequestOperationId(1);
  const selectedState = useDebuggerStore.getState();
  expect(selectedStackOperationId).not.toBe(oldStackOperationId);
  expect(selectedState.stoppedState?.threadId).toBe(2);
  expect(selectedState.stackFrames).toEqual([]);
  expect(selectedState.scopes).toEqual([]);
  expect(selectedState.variablesByReference).toEqual({});
  expect(selectedState.pendingRequests).toEqual({
    [selectedStackOperationId]: { command: "stackTrace", threadId: 2 },
  });

  await emitMessage("session-1", {
    type: "operationCompleted",
    operationId: oldStackOperationId,
    result: { kind: "stackTrace", stackFrames: [{ id: 12, name: "stale", line: 2, column: 1 }] },
  });
  expect(useDebuggerStore.getState().stackFrames).toEqual([]);

  await emitMessage("session-1", {
    type: "operationCompleted",
    operationId: selectedStackOperationId,
    result: { kind: "stackTrace", stackFrames: [{ id: 21, name: "current", line: 3, column: 1 }] },
  });

  const currentState = useDebuggerStore.getState();
  expect(currentState.stackFrames).toEqual([
    { id: 21, name: "current", line: 3, column: 1, sourcePath: undefined },
  ]);
  expect(currentState.selectedFrameId).toBe(21);
  expect(currentState.pendingRequests[getRequestOperationId(2)]).toEqual({
    command: "scopes",
    frameId: 21,
  });
});

test("normalized thread results fill the thread list and cascade further", async () => {
  await initializeDebuggerEventBridge();
  startSession("session-1");
  useDebuggerStore.getState().actions.registerAdapterRequest("threads-op", {
    command: "threads",
  });

  await emitMessage("session-1", {
    type: "operationCompleted",
    operationId: "threads-op",
    result: { kind: "threads", threads: [{ id: 1, name: "main" }] },
  });

  const state = useDebuggerStore.getState();
  expect(state.threads).toEqual([{ id: 1, name: "main" }]);
  expect(state.pendingRequests["threads-op"]).toBeUndefined();
  expect(sendDebugAdapterRequest).toHaveBeenCalledWith("session-1", "stackTrace", {
    threadId: 1,
  }, getRequestOperationId(0));
  expect(state.pendingRequests[getRequestOperationId(0)]).toEqual({
    command: "stackTrace",
    threadId: 1,
  });
});

test("evaluate results land in watch results for the correlated expression", async () => {
  await initializeDebuggerEventBridge();
  startSession("session-1");
  useDebuggerStore.getState().actions.registerAdapterRequest("debug-op-1", {
    command: "evaluate",
    expressionId: "watch-1",
  });

  await emitMessage("session-1", {
    type: "operationCompleted",
    operationId: "debug-op-1",
    result: {
      kind: "evaluate",
      variable: { name: "", value: "42", type: "number", variablesReference: 0 },
    },
  });

  const result = useDebuggerStore.getState().watchResults["watch-1"];
  expect(result?.value).toBe("42");
  expect(result?.type).toBe("number");
  expect(result?.error).toBeUndefined();
});

test("failed evaluate operations surface an actionable watch error", async () => {
  await initializeDebuggerEventBridge();
  startSession("session-1");
  useDebuggerStore.getState().actions.registerAdapterRequest("debug-op-1", {
    command: "evaluate",
    expressionId: "watch-2",
  });

  await emitMessage("session-1", {
    type: "operationFailed",
    operationId: "debug-op-1",
    command: "evaluate",
    code: "adapterRejected",
    message: "Expression could not be evaluated.",
  });

  const result = useDebuggerStore.getState().watchResults["watch-2"];
  expect(result?.error).toBe("Expression could not be evaluated.");
  expect(useDebuggerStore.getState().pendingRequests).toEqual({});
});

test("normalized output events reach the debug console", async () => {
  await initializeDebuggerEventBridge();

  await emitMessage("session-1", { type: "output", category: "stderr", output: "boom" });

  expect(useDebuggerStore.getState().adapterOutput).toEqual([
    { sessionId: "session-1", stream: "stderr", data: "boom" },
  ]);
});

test("terminated events end only the matching session", async () => {
  await initializeDebuggerEventBridge();
  startSession("session-1");

  await emitMessage("session-1", { type: "terminated", exitCode: 0 });

  expect(useDebuggerStore.getState().activeSession?.status).toBe("idle");
  expect(useDebuggerStore.getState().endedSessions).toEqual([]);
});

test("session-ended events preserve the native terminal reason for presentation", async () => {
  await initializeDebuggerEventBridge();
  startSession("session-1");

  capturedHandlers.onSessionEnded?.({ sessionId: "session-1", reason: "failed" });

  const state = useDebuggerStore.getState();
  expect(state.activeSession?.status).toBe("idle");
  expect(state.endedSessions).toEqual([{ sessionId: "session-1", reason: "failed" }]);

  state.actions.clearAdapterTranscript();
  expect(useDebuggerStore.getState().endedSessions).toEqual([
    { sessionId: "session-1", reason: "failed" },
  ]);
});

test("late session-ended events do not clear a restarted session", async () => {
  await initializeDebuggerEventBridge();
  startSession("session-1");
  startSession("session-2");
  useDebuggerStore.getState().actions.setStoppedState({ reason: "breakpoint", threadId: 2 });

  capturedHandlers.onSessionEnded?.({ sessionId: "session-1", reason: "exited" });

  const state = useDebuggerStore.getState();
  expect(state.activeSession?.id).toBe("session-2");
  expect(state.activeSession?.status).toBe("running");
  expect(state.stoppedState?.threadId).toBe(2);
  expect(state.endedSessions).toEqual([{ sessionId: "session-1", reason: "exited" }]);
});

test("stale events from a previous session cannot modify a restarted session", async () => {
  await initializeDebuggerEventBridge();
  startSession("session-1");
  await emitMessage("session-1", { type: "stopped", reason: "breakpoint", threadId: 3 });
  expect(useDebuggerStore.getState().activeSession?.status).toBe("paused");

  startSession("session-2");
  const requestCountAfterRestart = sendDebugAdapterRequest.mock.calls.length;

  await emitMessage("session-1", {
    type: "operationCompleted",
    operationId: "stale-stack-op",
    result: { kind: "stackTrace", stackFrames: [{ id: 7, name: "old", line: 1, column: 1 }] },
  });
  await emitMessage("session-1", { type: "stopped", reason: "breakpoint", threadId: 99 });

  const state = useDebuggerStore.getState();
  expect(state.activeSession?.id).toBe("session-2");
  expect(state.activeSession?.status).toBe("running");
  expect(state.stoppedState).toBeNull();
  expect(state.stackFrames).toEqual([]);
  expect(sendDebugAdapterRequest.mock.calls.length).toBe(requestCountAfterRestart);
});

test("failed states end the session and request native teardown", async () => {
  await initializeDebuggerEventBridge();
  startSession("session-1");

  await emitMessage("session-1", { type: "stateChanged", state: "failed" });

  const state = useDebuggerStore.getState();
  expect(state.activeSession?.status).toBe("idle");
  expect(state.adapterOutput).toEqual([
    { sessionId: "session-1", stream: "stderr", data: "The debug session failed.\n" },
  ]);
  expect(state.endedSessions).toEqual([]);
  expect(stopDebugAdapterSession).toHaveBeenCalledWith("session-1");
});
