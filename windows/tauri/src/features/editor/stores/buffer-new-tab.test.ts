import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { getBufferById } from "../utils/buffer-index";
import type { EditorContent } from "@/features/panes/types/pane-content.types";
import { useBufferStore } from "./buffer.store";

const WORKSPACE = "buffer-new-tab-test";

function getActiveEditor(): EditorContent {
  const { buffers, activeBufferId } = useBufferStore.getStore(WORKSPACE).getState();
  const buffer = activeBufferId ? getBufferById(buffers, activeBufferId) : undefined;
  if (!buffer || buffer.type !== "editor") {
    throw new Error("Expected an active editor buffer");
  }
  return buffer;
}

beforeEach(() => {
  workspaceRuntimeRegistry.resetForTests();
  workspaceRuntimeRegistry.ensureWorkspace({ id: WORKSPACE, name: "New Tab" }, "ready");
});

afterEach(() => {
  useBufferStore.getStore(WORKSPACE).setState({ buffers: [], activeBufferId: null });
});

describe("showNewTabView", () => {
  test("opens an editable, savable blank untitled editor buffer", () => {
    useBufferStore.getStore(WORKSPACE).getState().actions.showNewTabView();

    const active = getActiveEditor();
    expect(active.path.startsWith("untitled:")).toBe(true);
    expect(active.content).toBe("");
    expect(active.isVirtual).toBe(true);
  });

  test("numbers additional untitled buffers instead of reusing one", () => {
    const store = useBufferStore.getStore(WORKSPACE);
    store.getState().actions.showNewTabView();
    store.getState().actions.showNewTabView();

    const untitled = store
      .getState()
      .buffers.filter((buffer) => buffer.path.startsWith("untitled:"));
    expect(untitled).toHaveLength(2);
    expect(new Set(untitled.map((buffer) => buffer.path)).size).toBe(2);
  });
});
