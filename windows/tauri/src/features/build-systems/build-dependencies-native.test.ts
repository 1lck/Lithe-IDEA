import { afterEach, expect, spyOn, test } from "bun:test";
import * as tauri from "@/platform/tauri-core";
import { buildDependenciesNative } from "./build-dependencies-native";
import { validDependencies } from "./build-dependencies-types";
const cleanups: Array<() => void> = [];
afterEach(() =>
  cleanups
    .splice(0)
    .reverse()
    .forEach((cleanup) => cleanup()),
);

test("dependency IPC sends only native IDs and single-use operation confirmation", async () => {
  const calls: unknown[] = [];
  const invoke = spyOn(tauri, "invoke").mockImplementation(
    async <T>(command: string, args?: unknown): Promise<T> => {
      calls.push({ command, args });
      return null as T;
    },
  );
  cleanups.push(() => invoke.mockRestore());
  await buildDependenciesNative.prepare("D:/fixture", "dev.fixture", "build", "nested", {
    projectId: "native-project",
  });
  await buildDependenciesNative.execute("native-operation");
  await buildDependenciesNative.cancel("native-operation");
  expect(calls).toEqual([
    {
      command: "declarative_plugins_build_prepare_dependencies",
      args: {
        workspaceRoot: "D:/fixture",
        pluginId: "dev.fixture",
        buildSystemId: "build",
        root: "nested",
        selection: { projectId: "native-project" },
      },
    },
    {
      command: "declarative_plugins_build_load_dependencies",
      args: { operationId: "native-operation" },
    },
    {
      command: "declarative_plugins_build_cancel_operation",
      args: { operationId: "native-operation" },
    },
  ]);
});

test("Core trees retain arbitrary string properties and reject malformed or excessive trees", () => {
  expect(
    validDependencies([
      {
        name: "artifact",
        group: "group",
        version: "1",
        scope: "compile",
        properties: { resolution: "omittedForConflict", selectedVersion: "2" },
        children: [],
      },
    ]),
  ).toBe(true);
  expect(validDependencies([{ name: "artifact", children: "output text" }])).toBe(false);
  expect(
    validDependencies([{ name: "artifact", properties: { resolution: 1 }, children: [] }]),
  ).toBe(false);
  expect(
    validDependencies(Array.from({ length: 10_001 }, () => ({ name: "artifact", children: [] }))),
  ).toBe(false);
  const cycle = { name: "cycle", children: [] as unknown[] };
  cycle.children.push(cycle);
  expect(validDependencies([cycle])).toBe(false);
});
