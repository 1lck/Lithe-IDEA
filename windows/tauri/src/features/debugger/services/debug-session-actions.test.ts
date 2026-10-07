import { afterEach, expect, spyOn, test } from "bun:test";
import * as adapter from "./debug-adapter-service";
import { registerDebugSessionCleanup } from "./debug-session-resources";
import { stopOwnedDebugSession, sendActiveDebugThreadRequest } from "./debug-session-actions";
import { useDebuggerStore } from "../stores/debugger.store";
const initial = useDebuggerStore.getState();
afterEach(() => useDebuggerStore.setState(initial, true));
const session = {
  id: "owned-dap",
  configId: "boot",
  name: "Boot",
  command: "tcp",
  startedAt: 1,
  status: "paused" as const,
  adapterSession: true,
};

test("adapter Stop releases the registered execution once and preserves a replacement session", async () => {
  const nativeStop = spyOn(adapter, "stopDebugAdapterSession").mockResolvedValue(undefined);
  let finish!: () => void;
  const gate = new Promise<void>((resolve) => {
    finish = resolve;
  });
  let cleanups = 0;
  registerDebugSessionCleanup(session.id, async () => {
    cleanups++;
    await gate;
  });
  useDebuggerStore.setState({ activeSession: session });
  const first = stopOwnedDebugSession(session),
    second = stopOwnedDebugSession(session);
  try {
    expect(first).toBe(second);
    useDebuggerStore.setState({ activeSession: { ...session, id: "replacement" } });
  } finally {
    finish();
    await Promise.all([first, second]);
    nativeStop.mockRestore();
  }
  expect(cleanups).toBe(1);
  expect(useDebuggerStore.getState().activeSession?.id).toBe("replacement");
  expect(useDebuggerStore.getState().activeSession?.status).toBe("paused");
});

test("step and resume use the stopped DAP thread, not a terminal command", async () => {
  const request = spyOn(adapter, "sendDebugAdapterRequest").mockResolvedValue({
    sessionId: session.id,
    operationId: "step",
  });
  useDebuggerStore.setState({
    activeSession: session,
    stoppedState: { reason: "breakpoint", threadId: 7 },
  });
  try {
    await sendActiveDebugThreadRequest("next");
    expect(request).toHaveBeenCalledWith(session.id, "next", { threadId: 7 });
    expect(useDebuggerStore.getState().activeSession?.status).toBe("running");
    await sendActiveDebugThreadRequest("stepIn");
    expect(request).toHaveBeenCalledTimes(1);
  } finally {
    request.mockRestore();
  }
});

test("a fast stopped event before the transport acknowledgement stays paused and can step again", async () => {
  const request = spyOn(adapter, "sendDebugAdapterRequest").mockImplementation(async () => {
    useDebuggerStore.getState().actions.setStoppedState({ reason: "step", threadId: 7 });
    useDebuggerStore.getState().actions.setSessionStatus("paused");
    return { sessionId: session.id, operationId: "fast-step" };
  });
  useDebuggerStore.setState({
    activeSession: session,
    stoppedState: { reason: "breakpoint", threadId: 7 },
  });
  try {
    await sendActiveDebugThreadRequest("next");
    expect(useDebuggerStore.getState().activeSession?.status).toBe("paused");
    await sendActiveDebugThreadRequest("next");
    expect(request).toHaveBeenCalledTimes(2);
    expect(useDebuggerStore.getState().activeSession?.status).toBe("paused");
  } finally {
    request.mockRestore();
  }
});

test("a rejected step restores the previous pause without touching a newer event", async () => {
  const request = spyOn(adapter, "sendDebugAdapterRequest").mockRejectedValue(
    new Error("Disconnected"),
  );
  useDebuggerStore.setState({
    activeSession: session,
    stoppedState: { reason: "breakpoint", threadId: 7 },
  });
  try {
    await expect(sendActiveDebugThreadRequest("next")).rejects.toThrow("Disconnected");
    expect(useDebuggerStore.getState().activeSession?.status).toBe("paused");
  } finally {
    request.mockRestore();
  }
});
