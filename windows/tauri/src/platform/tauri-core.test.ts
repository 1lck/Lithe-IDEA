import { beforeEach, expect, mock, test } from "bun:test";

const tauriInvoke = mock(async () => undefined);

mock.module("@tauri-apps/api/core", () => ({
  Channel: class {},
  convertFileSrc: (path: string) => path,
  invoke: tauriInvoke,
}));

const { HostCommandError, invoke, isPlatformDispatcherCommand } = await import("./tauri-core");

beforeEach(() => {
  tauriInvoke.mockClear();
});

test("Java index maintenance routes directly to the Tauri host", async () => {
  const args = {
    workspacePath: "C:/fixture/project",
    workspaceFingerprint: "build=|modules=|jdtls=1.38.0",
  };

  expect(isPlatformDispatcherCommand("lsp_rebuild_java_index")).toBe(false);
  await invoke("lsp_rebuild_java_index", args);

  expect(tauriInvoke).toHaveBeenCalledWith("lsp_rebuild_java_index", args, undefined);
});

test("Maven host commands route directly instead of through the platform dispatcher", async () => {
  // Regression for #970: these were registered Tauri commands that the old
  // native allowlist omitted, so the dispatcher rejected every call.
  for (const command of [
    "maven_create_dependency_output",
    "maven_remove_dependency_output",
    "maven_resolve_installation",
    "maven_resolve_effective_configuration",
    "run_execute_prelaunch",
  ]) {
    tauriInvoke.mockClear();
    await invoke(command, { sessionId: "fixture" });
    expect(tauriInvoke).toHaveBeenCalledWith(command, { sessionId: "fixture" }, undefined);
  }
});

test("a string rejection from a host command surfaces as an Error with the host message", async () => {
  tauriInvoke.mockImplementationOnce(async () => {
    throw "Maven settings file is not readable";
  });

  const error = await invoke("maven_resolve_installation", { root: "C:/fixture" }).catch(
    (reason: unknown) => reason,
  );

  expect(error).toBeInstanceOf(HostCommandError);
  expect((error as Error).message).toBe("Maven settings file is not readable");
  expect(String(error)).toBe("Maven settings file is not readable");
  expect((error as InstanceType<typeof HostCommandError>).command).toBe("maven_resolve_installation");
});

test("a structured rejection keeps its code and details", async () => {
  tauriInvoke.mockImplementationOnce(async () => {
    throw { code: "processStartFailed", message: "Maven did not start", details: "exit 1" };
  });

  const error = (await invoke("run_start_process", {}).catch((reason: unknown) => reason)) as Error & {
    code?: string;
    details?: unknown;
  };

  expect(error).toBeInstanceOf(Error);
  expect(error.message).toBe("Maven did not start");
  expect(error.code).toBe("processStartFailed");
  expect(error.details).toBe("exit 1");
});

test("a dispatcher rejection surfaces as an Error", async () => {
  tauriInvoke.mockImplementationOnce(async () => {
    throw "Shared core task failed";
  });

  const error = await invoke("git.consolePresentation", {}).catch((reason: unknown) => reason);

  expect(error).toBeInstanceOf(Error);
  expect((error as Error).message).toBe("Shared core task failed");
});

test("pure console projection bypasses execution events and Git settings", async () => {
  const args = { records: [], search: "" };
  await invoke("git.consolePresentation", args);
  expect(tauriInvoke).toHaveBeenCalledWith("platform_invoke", { command: "git.consolePresentation", args }, undefined);
});

test("explicit automatic provenance is forwarded separately from native invoke options", async () => {
  await invoke("git_status", { repoPath: "C:/fixture/project", operationId: "background-fixture" }, { gitExecutionSource: "background" });
  const calls = tauriInvoke.mock.calls as unknown as [string, { gitExecution?: { source?: string }; gitEvents?: unknown }, unknown][];
  expect(calls[0]![1].gitExecution?.source).toBe("background");
  expect(calls[0]![1].gitEvents).toBeDefined();
  expect(calls[0]![2]).toBeUndefined();
});

test("native headers survive Git provenance forwarding", async () => {
  const headers = { "X-Fixture": "console" };
  await invoke("git_status", { repoPath: "C:/fixture/project", operationId: "headers-fixture" }, {
    headers,
    gitExecutionSource: "user",
  });
  const calls = tauriInvoke.mock.calls as unknown as [string, { gitExecution?: { source?: string } }, unknown][];
  expect(calls[0]![1].gitExecution?.source).toBe("user");
  expect(calls[0]![2]).toEqual({ headers });
});
