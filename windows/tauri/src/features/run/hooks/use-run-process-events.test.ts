import { beforeEach, describe, expect, mock, test } from "bun:test";

const eventHandlers = new Map<string, (event: { payload: unknown }) => void>();
const windowListen = mock(async (event: string, handler: (event: { payload: unknown }) => void) => {
  eventHandlers.set(event, handler);
  return () => {
    eventHandlers.delete(event);
  };
});
const globalListen = mock(async () => () => {});
const appendOutput = mock(() => undefined);
const finishProcess = mock(() => undefined);
const releaseRunSessionWorkspace = mock(() => undefined);

const actualRunStore = await import("../stores/run.store");

mock.module("@tauri-apps/api/webviewWindow", () => ({
  getCurrentWebviewWindow: () => ({
    label: "project-window",
    listen: windowListen,
  }),
}));
mock.module("@tauri-apps/api/event", () => ({ listen: globalListen }));
mock.module("../stores/run.store", () => ({
  ...actualRunStore,
  runStoreForSession: () => ({
    getState: () => ({
      actions: { appendOutput, finishProcess },
    }),
  }),
  releaseRunSessionWorkspace,
}));

const { ensureRunProcessListeners } = await import("./use-run-process-events");

describe("run process event listeners", () => {
  beforeEach(() => {
    appendOutput.mockClear();
    finishProcess.mockClear();
    releaseRunSessionWorkspace.mockClear();
  });

  test("registers run-output and run-exit on the current webview window", async () => {
    await ensureRunProcessListeners();

    expect(windowListen).toHaveBeenCalledTimes(2);
    expect(windowListen).toHaveBeenCalledWith("run-output", expect.any(Function));
    expect(windowListen).toHaveBeenCalledWith("run-exit", expect.any(Function));
    expect(globalListen).not.toHaveBeenCalled();
    expect(eventHandlers.has("run-output")).toBe(true);
    expect(eventHandlers.has("run-exit")).toBe(true);
  });

  test("does not register duplicate listeners on repeated setup", async () => {
    const callsBefore = windowListen.mock.calls.length;
    await ensureRunProcessListeners();
    expect(windowListen.mock.calls.length).toBe(callsBefore);
    expect(globalListen).not.toHaveBeenCalled();
  });

  test("routes output events through the run store for this window", () => {
    const outputHandler = eventHandlers.get("run-output");
    expect(outputHandler).toBeDefined();

    outputHandler?.({
      payload: { sessionId: "primary", chunk: "hello\n" },
    });

    expect(appendOutput).toHaveBeenCalledWith("primary", "hello\n");
  });
});
