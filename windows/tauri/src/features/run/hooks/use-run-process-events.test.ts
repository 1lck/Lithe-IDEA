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
const declarativeFinished = mock(() => undefined);

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
});
