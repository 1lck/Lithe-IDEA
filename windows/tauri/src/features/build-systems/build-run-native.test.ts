import { afterEach, expect, spyOn, test } from "bun:test";
import * as native from "@/platform/tauri-core";
import * as events from "@tauri-apps/api/event";
import { buildRunNative } from "./build-run-native";
import type { BuildRunSelection } from "./build-run-types";

const cleanups: Array<() => void> = [];
afterEach(() => {
  cleanups
    .splice(0)
    .reverse()
    .forEach((cleanup) => cleanup());
});

test("task/test IPC sends only native serde selection fields; the host supplies window and executable identity", async () => {
  const calls: Array<{ command: string; args: unknown }> = [];
  const invoke = spyOn(native, "invoke").mockImplementation(
    async <T>(command: string, args?: unknown): Promise<T> => {
      calls.push({ command, args });
      return (command.endsWith("execute_run") ? { kind: "succeeded", exitCode: 0 } : null) as T;
    },
  );
  cleanups.push(() => invoke.mockRestore());
  const selection: BuildRunSelection = {
    kind: "test",
    taskId: null,
    projectId: "project-id",
    targetId: "target-id",
    modelTaskId: null,
    suite: "fixture suite",
    case: "fixture case",
    userArguments: ["literal value with spaces"],
  };
  await buildRunNative.prepare(
    "D:/fixture/workspace",
    "dev.fixture.plugin",
    "fixture-system",
    "nested",
    selection,
  );
  await buildRunNative.execute("native-operation");
  await buildRunNative.cancel("native-operation");
  expect(calls).toEqual([
    {
      command: "declarative_plugins_build_prepare_run",
      args: {
        workspaceRoot: "D:/fixture/workspace",
        pluginId: "dev.fixture.plugin",
        buildSystemId: "fixture-system",
        root: "nested",
        selection,
      },
    },
    { command: "declarative_plugins_build_execute_run", args: { operationId: "native-operation" } },
    {
      command: "declarative_plugins_build_cancel_operation",
      args: { operationId: "native-operation" },
    },
  ]);
});
test("output subscription uses the native window target and returns its actual unlistener", async () => {
  let listener: ((event: { payload: unknown }) => void) | undefined;
  const off = () => {};
  const listen = spyOn(events, "listen").mockImplementation(async (_event, callback) => {
    listener = callback as typeof listener;
    return off;
  });
  cleanups.push(() => listen.mockRestore());
  const received: unknown[] = [];
  const release = await buildRunNative.listen("workspace-window-A", (event) =>
    received.push(event),
  );
  expect(listen).toHaveBeenCalledWith("declarative-build-output", expect.any(Function), {
    target: { kind: "Window", label: "workspace-window-A" },
  });
  const payload = {
    operationId: "native-operation",
    pluginId: "dev.fixture.plugin",
    buildSystemId: "fixture-system",
    workspaceRoot: "D:/fixture/workspace",
    root: ".",
    generation: 7,
    type: "chunk",
    stream: "stdout",
    text: "first",
  };
  listener!({ payload });
  expect(received).toEqual([payload]);
  expect(release).toBe(off);
});
