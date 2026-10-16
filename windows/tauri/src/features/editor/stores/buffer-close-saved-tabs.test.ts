import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import type { EditorContent, PaneContent } from "@/features/panes/types/pane-content.types";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { useBufferStore } from "./buffer.store";

const WORKSPACE = "close-saved-tabs-test";

function editorBuffer(id: string, overrides: Partial<EditorContent> = {}): EditorContent {
  return {
    id,
    type: "editor",
    // Virtual buffers keep the test hermetic: closing a real file path would
    // pull in the language-server client.
    path: `untitled:${id}`,
    name: id,
    content: "",
    savedContent: "",
    isDirty: false,
    isVirtual: true,
    isPinned: false,
    isPreview: false,
    isActive: false,
    tokens: [],
    ...overrides,
  };
}

function bufferStore() {
  return useBufferStore.getStore(WORKSPACE);
}

function openBufferIds(): string[] {
  return bufferStore()
    .getState()
    .buffers.map((buffer) => buffer.id);
}

beforeEach(() => {
  workspaceRuntimeRegistry.resetForTests();
  workspaceRuntimeRegistry.ensureWorkspace({ id: WORKSPACE, name: "Workspace" }, "ready");
});

afterEach(() => {
  bufferStore().setState({ buffers: [], activeBufferId: null });
});

describe("handleCloseSavedTabs", () => {
  test("closes clean tabs and keeps the ones with unsaved edits", () => {
    const clean = editorBuffer("clean");
    const dirty = editorBuffer("dirty", { isDirty: true, content: "draft" });
    bufferStore().setState({ buffers: [clean, dirty] as PaneContent[], activeBufferId: dirty.id });

    bufferStore().getState().actions.handleCloseSavedTabs();

    expect(openBufferIds()).toEqual([dirty.id]);
    // The kept tab must still go through the normal close confirmation.
    expect(bufferStore().getState().pendingClose).toBeNull();
  });

  test("keeps pinned tabs even when they have no unsaved edits", () => {
    const pinned = editorBuffer("pinned", { isPinned: true });
    const unpinned = editorBuffer("unpinned");
    bufferStore().setState({
      buffers: [pinned, unpinned] as PaneContent[],
      activeBufferId: unpinned.id,
    });

    bufferStore().getState().actions.handleCloseSavedTabs();

    expect(openBufferIds()).toEqual([pinned.id]);
  });
});
