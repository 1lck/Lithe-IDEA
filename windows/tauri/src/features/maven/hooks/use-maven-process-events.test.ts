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
const appendDependencyOutput = mock(() => undefined);
const finishProcess = mock(() => undefined);
const finishDependencyProcess = mock(async () => undefined);
const releaseMavenSessionWorkspace = mock(() => undefined);

mock.module("@tauri-apps/api/webviewWindow", () => ({
  getCurrentWebviewWindow: () => ({
    label: "workspace-1",
    listen: windowListen,
  }),
}));
mock.module("@tauri-apps/api/event", () => ({ listen: globalListen }));
mock.module("../stores/maven.store", () => ({
  mavenStoreForSession: () => ({
    getState: () => ({
      actions: {
        appendOutput,
        appendDependencyOutput,
        finishProcess,
        finishDependencyProcess,
      },
    }),
  }),
  releaseMavenSessionWorkspace,
}));

const { ensureMavenProcessListeners } = await import("./use-maven-process-events");

describe("maven process event listeners", () => {
  beforeEach(() => {
    appendOutput.mockClear();
    appendDependencyOutput.mockClear();
    finishProcess.mockClear();
    finishDependencyProcess.mockClear();
    releaseMavenSessionWorkspace.mockClear();
  });

  test("registers run-output and run-exit on the current webview window", async () => {
    await ensureMavenProcessListeners();

    expect(windowListen).toHaveBeenCalledTimes(2);
    expect(windowListen).toHaveBeenCalledWith("run-output", expect.any(Function));
    expect(windowListen).toHaveBeenCalledWith("run-exit", expect.any(Function));
    expect(globalListen).not.toHaveBeenCalled();
    expect(eventHandlers.has("run-output")).toBe(true);
    expect(eventHandlers.has("run-exit")).toBe(true);
  });

  test("ignores non-maven session output", () => {
    const outputHandler = eventHandlers.get("run-output");
    expect(outputHandler).toBeDefined();

    outputHandler?.({
      payload: { sessionId: "primary", chunk: "leaked\n" },
    });

    expect(appendOutput).not.toHaveBeenCalled();
  });

  test("routes maven session output through the maven store", () => {
    const outputHandler = eventHandlers.get("run-output");
    expect(outputHandler).toBeDefined();

    outputHandler?.({
      payload: { sessionId: "maven:task-1", chunk: "BUILD SUCCESS\n" },
    });

    expect(appendOutput).toHaveBeenCalledWith("maven:task-1", "BUILD SUCCESS\n");
  });

  test("routes dependency sessions without mutating build output", () => {
    const outputHandler = eventHandlers.get("run-output");
    const exitHandler = eventHandlers.get("run-exit");
    expect(outputHandler).toBeDefined();
    expect(exitHandler).toBeDefined();

    outputHandler?.({
      payload: { sessionId: "maven-dependency:task-1", chunk: "[INFO] tree\n" },
    });
    exitHandler?.({
      payload: { sessionId: "maven-dependency:task-1", exitCode: 0 },
    });

    expect(appendDependencyOutput).toHaveBeenCalledWith(
      "maven-dependency:task-1",
      "[INFO] tree\n",
    );
    expect(appendOutput).not.toHaveBeenCalled();
    expect(finishDependencyProcess).toHaveBeenCalledWith("maven-dependency:task-1", 0);
  });
});
