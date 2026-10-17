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

  test("opens a new blank page after the lower-numbered untitled tab was closed", () => {
    const store = useBufferStore.getStore(WORKSPACE);
    store.getState().actions.showNewTabView();
    store.getState().actions.showNewTabView();

    const opened = store
      .getState()
      .buffers.filter((buffer) => buffer.path.startsWith("untitled:"));
    expect(opened).toHaveLength(2);

    // Closing the first tab leaves a single untitled tab behind. Counting the remaining
    // tabs used to reproduce the path of that tab, so the next new tab only focused it.
    const remaining = opened.slice(1);
    store.setState({ buffers: remaining, activeBufferId: remaining[0]?.id ?? null });

    store.getState().actions.showNewTabView();

    const untitled = store
      .getState()
      .buffers.filter((buffer) => buffer.path.startsWith("untitled:"));
    expect(untitled).toHaveLength(2);
    expect(new Set(untitled.map((buffer) => buffer.path)).size).toBe(2);
  });

  test("marks edits on the new tab dirty so closing asks before discarding them", () => {
    const store = useBufferStore.getStore(WORKSPACE);
    store.getState().actions.showNewTabView();

    const active = getActiveEditor();
    store.getState().actions.updateBufferContent(active.id, "unsaved draft");

    expect(getActiveEditor().isDirty).toBe(true);

    store.getState().actions.closeBuffer(active.id);
    expect(store.getState().pendingClose?.bufferId).toBe(active.id);
  });

  test("keeps a dirty untitled tab instead of evicting it at the tab limit", () => {
    const store = useBufferStore.getStore(WORKSPACE);
    store.setState({ maxOpenTabs: 1 });

    store.getState().actions.showNewTabView();
    const first = getActiveEditor();
    store.getState().actions.updateBufferContent(first.id, "unsaved draft");

    store.getState().actions.showNewTabView();

    const buffers = store.getState().buffers;
    expect(buffers.some((buffer) => buffer.id === first.id)).toBe(true);
    expect(buffers.filter((buffer) => buffer.path.startsWith("untitled:"))).toHaveLength(2);
  });

  test("evicts a clean untitled tab once the tab limit is reached", () => {
    const store = useBufferStore.getStore(WORKSPACE);
    store.setState({ maxOpenTabs: 1 });

    store.getState().actions.showNewTabView();
    const first = getActiveEditor();
    store.getState().actions.showNewTabView();

    expect(store.getState().buffers.some((buffer) => buffer.id === first.id)).toBe(false);
  });
});
