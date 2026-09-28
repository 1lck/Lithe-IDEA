import { beforeEach, expect, mock, test } from "bun:test";

const tauriInvoke = mock(async () => undefined);

mock.module("@tauri-apps/api/core", () => ({
  Channel: class {},
  convertFileSrc: (path: string) => path,
  invoke: tauriInvoke,
}));

const { invoke, isNativeCommand } = await import("./tauri-core");

beforeEach(() => {
  tauriInvoke.mockClear();
});

test("Java index maintenance routes directly to the Tauri host", async () => {
  const args = {
    workspacePath: "C:/fixture/project",
    workspaceFingerprint: "build=|modules=|jdtls=1.38.0",
  };

  expect(isNativeCommand("lsp_rebuild_java_index")).toBe(true);
  await invoke("lsp_rebuild_java_index", args);

  expect(tauriInvoke).toHaveBeenCalledWith("lsp_rebuild_java_index", args, undefined);
});


test("Agent connection commands route directly to the Tauri host", async () => {
  const args = { connectionId: "fixture-connection", command: { authenticate: null } };

  expect(isNativeCommand("agent_open")).toBe(true);
  expect(isNativeCommand("agent_send")).toBe(true);
  expect(isNativeCommand("agent_close")).toBe(true);

  await invoke("agent_open", args);
  await invoke("agent_close", { connectionId: "fixture-connection" });

  expect(tauriInvoke).toHaveBeenCalledWith("agent_open", args, undefined);
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
