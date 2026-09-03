import { beforeEach, describe, expect, mock, test } from "bun:test";

const invoke = mock(async () => undefined);

mock.module("@/platform/tauri-core", () => ({
  invoke,
  Channel: class {},
  convertFileSrc: (path: string) => path,
}));
mock.module("../utils/run-window-context", () => ({
  getRunWindowLabel: () => "project-window",
}));

const { startRunProcess, stopRunProcess, writeRunStdin } = await import("../api/run-host-api");

describe("run host API window scoping", () => {
  beforeEach(() => {
    invoke.mockClear();
  });

  test("startRunProcess includes the current window label", async () => {
    await startRunProcess({
      sessionId: "primary",
      executable: "go.exe",
      arguments: ["run", "."],
      workingDirectory: "D:\\demo",
      environment: {},
    });

    expect(invoke).toHaveBeenCalledWith("run_start_process", {
      args: {
        sessionId: "primary",
        executable: "go.exe",
        arguments: ["run", "."],
        workingDirectory: "D:\\demo",
        environment: {},
        windowLabel: "project-window",
      },
    });
  });

  test("stop and stdin commands include the current window label", async () => {
    await stopRunProcess("primary");
    await writeRunStdin("primary", "input\n");

    expect(invoke).toHaveBeenNthCalledWith(1, "run_stop_process", {
      windowLabel: "project-window",
      sessionId: "primary",
    });
    expect(invoke).toHaveBeenNthCalledWith(2, "run_write_stdin", {
      windowLabel: "project-window",
      sessionId: "primary",
      input: "input\n",
    });
  });
});
