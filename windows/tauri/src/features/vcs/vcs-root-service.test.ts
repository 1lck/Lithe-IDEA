import { afterEach, expect, mock, test } from "bun:test";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { setPluginActive } from "@/features/plugins/declarative-plugin-lifecycle";
import type { VcsScope, VcsSnapshot } from "./vcs-root-types";

const calls: Array<{ command: string; scope: VcsScope; generation?: number; paths?: string[] }> =
  [];
let generation = 0;
mock.module("@/platform/tauri-core", () => ({
  invoke: async (
    command: string,
    arguments_: { scope: VcsScope; generation?: number; paths?: string[] },
  ) => {
    calls.push({ command, ...arguments_ });
    if (command === "declarative_plugins_vcs_detect")
      return {
        generation: ++generation,
        workspaceId: arguments_.scope.workspaceId,
        workspaceRoot: arguments_.scope.workspaceRoot,
        detection: {
          providers: [],
          roots: [],
          ambiguous: [],
          unusedMappings: [],
          rejected: [],
          conflicts: [],
          truncated: false,
        },
      } satisfies VcsSnapshot;
    return {};
  },
}));
const { workspaceVcsRoots, closeWorkspaceVcsRoots } = await import("./vcs-root-service");
const ids = new Set<string>();
let sequence = 0;
function workspace(path = "C:/fixture/vcs-service") {
  const id = `vcs-service-${++sequence}`;
  ids.add(id);
  workspaceRuntimeRegistry.ensureWorkspace({ id, path, name: id }, "ready");
  return id;
}
async function flush() {
  for (let turn = 0; turn < 16; turn++) await Promise.resolve();
}
afterEach(async () => {
  for (const id of ids) await closeWorkspaceVcsRoots(id);
  ids.clear();
  workspaceRuntimeRegistry.resetForTests();
  calls.length = 0;
});

test("actual workspace service reuses one controller and calls only passive native commands", async () => {
  const id = workspace();
  const controller = workspaceVcsRoots(id)!;
  expect(workspaceVcsRoots(id)).toBe(controller);
  await controller.refresh();
  expect(calls[0]).toEqual({ command: "declarative_plugins_vcs_detect", scope: controller.scope });
  await closeWorkspaceVcsRoots(id);
  expect(calls[1]).toEqual({ command: "declarative_plugins_vcs_close", scope: controller.scope });
  expect(controller.getSnapshot().snapshot).toBeNull();
});

test("same-path reopen uses a new incarnation and retirement keeps the original scope", async () => {
  const id = workspace();
  const first = workspaceVcsRoots(id)!;
  await first.refresh();
  await closeWorkspaceVcsRoots(id);
  const second = workspaceVcsRoots(id)!;
  expect(second.scope.incarnation).not.toBe(first.scope.incarnation);
  expect(second.scope.workspaceRoot).toBe(first.scope.workspaceRoot);
  await second.refresh();
  expect(calls.filter((call) => call.command.endsWith("close"))[0].scope).toEqual(first.scope);
});

test("plugin lifecycle clears old roots and refreshes each ready workspace independently", async () => {
  const a = workspace(),
    b = workspace("C:/fixture/other-vcs-service");
  const first = workspaceVcsRoots(a)!,
    second = workspaceVcsRoots(b)!;
  await first.refresh();
  await second.refresh();
  const old = first.getSnapshot().snapshot;
  setPluginActive("fixture.vcs.plugin", false);
  expect(first.getSnapshot().snapshot).toBeNull();
  await flush();
  expect(first.getSnapshot().snapshot?.generation).not.toBe(old?.generation);
  expect(first.getSnapshot().snapshot?.workspaceId).toBe(a);
  expect(second.getSnapshot().snapshot?.workspaceId).toBe(b);
  setPluginActive("fixture.vcs.plugin", true);
  await flush();
});

test("runtime removal retires the workspace and preserves another workspace snapshot", async () => {
  const a = workspace(),
    b = workspace("C:/fixture/other-vcs-service");
  const first = workspaceVcsRoots(a)!,
    second = workspaceVcsRoots(b)!;
  await first.refresh();
  await second.refresh();
  const other = second.getSnapshot().snapshot;
  workspaceRuntimeRegistry.removeWorkspace(a);
  await flush();
  expect(first.getSnapshot().snapshot).toBeNull();
  expect(second.getSnapshot().snapshot).toBe(other);
  expect(calls.some((call) => call.command.endsWith("close") && call.scope.workspaceId === a)).toBe(
    true,
  );
});

test("remote or unready workspaces do not enter the local passive registry", () => {
  const remote = workspace("remote://fixture/project");
  expect(workspaceVcsRoots(remote)).toBeNull();
  const local = workspace();
  workspaceRuntimeRegistry.updateWorkspaceStatus(local, "opening");
  expect(workspaceVcsRoots(local)).toBeNull();
  expect(calls).toHaveLength(0);
});
