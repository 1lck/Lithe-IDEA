import { expect, spyOn, test } from "bun:test";
import { LspClient } from "../lsp/lsp-client";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import * as persistence from "./buffer-session-persistence";
import { createPaneContent } from "./buffer-content-factory";
import { useBufferStore } from "./buffer.store";

test("the buffer close import retains the original workspace when another workspace opens the same file", async () => {
  const suffix = crypto.randomUUID();
  const first = { id: `close-${suffix}`, name: "First", path: "C:/fixture" };
  const second = { id: `reopen-${suffix}`, name: "Second", path: "C:/other" };
  const previous = workspaceRuntimeRegistry.getActiveWorkspace();
  const path = "C:/fixture/acceptance.litheaccept";
  const oldBuffer = createPaneContent("closed-buffer", { type: "editor", path, name: "acceptance.litheaccept", content: "old" });
  const newBuffer = createPaneContent("new-buffer", { type: "editor", path, name: "acceptance.litheaccept", content: "new" });
  let entered!: () => void;
  const stopped = new Promise<void>((resolve) => { entered = resolve; });
  const calls: unknown[][] = [];
  const instance = spyOn(LspClient, "getInstance").mockReturnValue({
    stopForFile: async (...args: unknown[]) => { calls.push(args); entered(); },
  } as unknown as LspClient);
  const save = spyOn(persistence, "saveSessionToStore").mockImplementation(() => {});
  try {
    workspaceRuntimeRegistry.activateWorkspace(first, "ready");
    useFileSystemStore.getStore(first.id).setState({ rootFolderPath: first.path });
    const store = useBufferStore.getStore(first.id);
    store.setState({ buffers: [oldBuffer], activeBufferId: oldBuffer.id });
    store.getState().actions.closeBufferForce(oldBuffer.id);
    // The dynamic import's continuation runs after this synchronous switch.
    workspaceRuntimeRegistry.activateWorkspace(second, "ready");
    useFileSystemStore.getStore(second.id).setState({ rootFolderPath: second.path });
    useBufferStore.getStore(second.id).setState({ buffers: [newBuffer], activeBufferId: newBuffer.id });
    await stopped;
    expect(calls).toEqual([[path, undefined, { workspaceId: first.id, root: first.path }]]);
    expect(useBufferStore.getStore(second.id).getState().buffers).toEqual([newBuffer]);
  } finally {
    // Joining the cached import also drains the close callback on failure.
    await import("../lsp/lsp-client");
    instance.mockRestore(); save.mockRestore();
    if (previous) workspaceRuntimeRegistry.activateWorkspace(previous.descriptor, previous.status);
    workspaceRuntimeRegistry.removeWorkspace(first.id);
    workspaceRuntimeRegistry.removeWorkspace(second.id);
  }
}, 3000);
