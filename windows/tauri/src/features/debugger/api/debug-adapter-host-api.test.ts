import { beforeEach, expect, mock, test } from "bun:test";
import { createDebugAdapterHostApi, type DebugAdapterHostInvoke } from "./debug-adapter-host-api";

const invoke = mock(async (command: string) => {
  if (command === "debug_connect_session") {
    return { id: "java-debug-session", command: "tcp://127.0.0.1:4711", args: [] };
  }
  if (command === "debug_allocate_loopback_port") return 5005;
  return undefined;
});

const { allocateJvmDebugPort, connectDebugAdapterSession, waitForJvmDebugPort } =
  createDebugAdapterHostApi(invoke as unknown as DebugAdapterHostInvoke);

beforeEach(() => invoke.mockClear());

test("connects only to the native loopback adapter command", async () => {
  await expect(
    connectDebugAdapterSession({ port: 4711, workspacePath: "D:/work" }),
  ).resolves.toEqual({
    id: "java-debug-session",
    command: "tcp://127.0.0.1:4711",
    args: [],
  });
  expect(invoke).toHaveBeenCalledWith("debug_connect_session", {
    launch: { port: 4711, workspacePath: "D:/work" },
  });
});

test("uses the bounded native JDWP port lifecycle", async () => {
  await expect(allocateJvmDebugPort()).resolves.toBe(5005);
  await waitForJvmDebugPort(5005, 12_000);

  expect(invoke).toHaveBeenNthCalledWith(1, "debug_allocate_loopback_port");
  expect(invoke).toHaveBeenNthCalledWith(2, "debug_wait_for_port", {
    args: { port: 5005, timeoutMilliseconds: 12_000 },
  });
});
