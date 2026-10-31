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
const finishProcess = mock((): boolean | void => undefined);
const releaseRunSessionWorkspace = mock(() => undefined);
const declarativeFinished = mock(() => undefined);
let executionSnapshot: { primaryExecutionId?: string; sessions?: Array<{ id: string; executionId: string }> } = {};

const actualRunStore = await import("../stores/run.store");

mock.module("@tauri-apps/api/webviewWindow", () => ({
  getCurrentWebviewWindow: () => ({
    label: "project-window",
    listen: windowListen,
  }),
}));
mock.module("@tauri-apps/api/event", () => ({ listen: globalListen }));
mock.module("@/features/plugins/declarative-plugin-process-owner", () => ({
  declarativePluginProcessOwner: { finished: declarativeFinished },
}));
mock.module("../stores/run.store", () => ({
  ...actualRunStore,
  runStoreForSession: () => ({
    getState: () => ({
      ...executionSnapshot,
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
    declarativeFinished.mockClear();
    executionSnapshot = {};
    finishProcess.mockImplementation(() => undefined);
  });

  test("concurrent owners register run-output and run-exit only once on the current webview", async () => {
    await Promise.all([ensureRunProcessListeners(), ensureRunProcessListeners()]);

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

  test("releases declarative process ownership when a run exits", () => {
    const exitHandler = eventHandlers.get("run-exit");
    expect(exitHandler).toBeDefined();
    exitHandler?.({ payload: { sessionId: "declarative:php:1", exitCode: 0 } });
    expect(declarativeFinished).toHaveBeenCalledWith("declarative:php:1");
  });

  test("an old execution cannot append output or retire its replacement", () => {
    executionSnapshot = { primaryExecutionId: "new-execution" };
    const output = eventHandlers.get("run-output"), exit = eventHandlers.get("run-exit");
    output?.({ payload: { sessionId: "primary", executionId: "old-execution", chunk: "old" } });
    exit?.({ payload: { sessionId: "primary", executionId: "old-execution", exitCode: 1 } });
    exit?.({ payload: { sessionId: "primary", exitCode: 1 } });
    expect(appendOutput).not.toHaveBeenCalled(); expect(finishProcess).not.toHaveBeenCalled();
    expect(releaseRunSessionWorkspace).not.toHaveBeenCalled(); expect(declarativeFinished).not.toHaveBeenCalled();
    output?.({ payload: { sessionId: "primary", executionId: "new-execution", chunk: "current" } });
    exit?.({ payload: { sessionId: "primary", executionId: "new-execution", exitCode: 0 } });
    expect(appendOutput).toHaveBeenCalledWith("primary", "current");
    expect(declarativeFinished).toHaveBeenCalledWith("new-execution");
  }, 5000);

  test("Provider-owned exit leaves asynchronous source cleanup with its existing Run owner", async () => {
    await ensureRunProcessListeners(); executionSnapshot = { primaryExecutionId: "provider-execution" };
    finishProcess.mockImplementation(() => true);
    eventHandlers.get("run-exit")?.({ payload: { sessionId: "primary", executionId: "provider-execution", exitCode: 0 } });
    expect(finishProcess).toHaveBeenCalledWith("primary", 0); expect(declarativeFinished).not.toHaveBeenCalled();
  }, 5000);

  test("a restart triggered by exit publication retains its new session binding", () => {
    executionSnapshot = { primaryExecutionId: "exiting" };
    finishProcess.mockImplementation(() => { executionSnapshot = { primaryExecutionId: "restarted" }; });
    eventHandlers.get("run-exit")?.({ payload: { sessionId: "primary", executionId: "exiting", exitCode: 0 } });
    expect(finishProcess).toHaveBeenCalledWith("primary", 0);
    expect(releaseRunSessionWorkspace).not.toHaveBeenCalled();
    expect(declarativeFinished).toHaveBeenCalledWith("exiting");
  }, 5000);
});
