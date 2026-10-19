import { beforeEach, expect, mock, test } from "bun:test";

const tauriInvoke = mock(async () => undefined);

mock.module("@tauri-apps/api/core", () => ({
  Channel: class {},
  convertFileSrc: (path: string) => path,
  isTauri: () => true,
  invoke: tauriInvoke,
}));

const { Channel, HostCommandError, invoke, isPlatformDispatcherCommand } = await import("./tauri-core");

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

test("Agent connection commands route directly to the Tauri host", async () => {
  const args = { connectionId: "fixture-connection", command: { authenticate: null } };

  expect(isPlatformDispatcherCommand("agent_open")).toBe(false);
  expect(isPlatformDispatcherCommand("agent_send")).toBe(false);
  expect(isPlatformDispatcherCommand("agent_close")).toBe(false);

  await invoke("agent_open", args);
  await invoke("agent_send", { connectionId: "fixture-connection", command: { cancel: null } });
  await invoke("agent_close", { connectionId: "fixture-connection" });

  expect(tauriInvoke).toHaveBeenCalledWith("agent_open", args, undefined);
  expect(tauriInvoke).toHaveBeenCalledWith(
    "agent_send",
    { connectionId: "fixture-connection", command: { cancel: null } },
    undefined,
  );
  expect(tauriInvoke).toHaveBeenCalledWith(
    "agent_close",
    { connectionId: "fixture-connection" },
    undefined,
  );
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

test("an adapter install forwards its progress channel to the platform dispatcher", async () => {
  const agentEvents = new Channel<unknown>();
  await invoke(
    "agent.install",
    { dataDirectory: "C:/fixture/data", agentId: "codex-acp" },
    { agentEvents },
  );
  const calls = tauriInvoke.mock.calls as unknown as [
    string,
    { command?: string; agentEvents?: unknown; gitEvents?: unknown },
    unknown,
  ][];
  expect(calls[0]![0]).toBe("platform_invoke");
  expect(calls[0]![1].command).toBe("agent.install");
  expect(calls[0]![1].agentEvents).toBe(agentEvents);
  // An install progress channel is not a Git console channel.
  expect(calls[0]![1].gitEvents).toBeUndefined();
});

test("a command without a progress channel keeps the dispatcher payload unchanged", async () => {
  await invoke("agent.status", { dataDirectory: "C:/fixture/data" });
  const calls = tauriInvoke.mock.calls as unknown as [string, unknown][];
  expect(calls[0]![1]).toEqual({
    command: "agent.status",
    args: { dataDirectory: "C:/fixture/data" },
  });
});

test("a raw Core result bypasses the compatibility adapter but keeps Git provenance", async () => {
  // The diff adapter strips CR and end-of-file markers from `git.diff`; the
  // byte-faithful rollback channel must read the patch exactly as Core sent it.
  const core = { patch: "@@ -1 +1 @@\n-a\r\n+b\r\n\\ No newline at end of file\n", exitCode: 0, hasDecodingLoss: false };
  tauriInvoke.mockImplementationOnce((async () => core) as never);
  const raw = await invoke("git.diff", { root: "C:/fixture/project", pathspecs: ["a.txt"] }, { rawCoreResult: true });
  expect(raw).toBe(core);
  const calls = tauriInvoke.mock.calls as unknown as [string, { gitEvents?: unknown }, unknown][];
  expect(calls[0]![1].gitEvents).toBeDefined();
  // The option is local metadata, never forwarded as native invoke options.
  expect(calls[0]![2]).toBeUndefined();

  tauriInvoke.mockImplementationOnce((async () => core) as never);
  const adapted = await invoke<unknown>("git.diff", { root: "C:/fixture/project", pathspecs: ["a.txt"] });
  expect(Array.isArray(adapted)).toBe(true);
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
