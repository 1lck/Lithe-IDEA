import { beforeEach, describe, expect, spyOn, test } from "bun:test";
import { toast } from "sonner";
import type { EditorContent } from "@/features/panes/types/pane-content.types";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { getBufferById } from "../utils/buffer-index";
import { useBufferStore } from "./buffer.store";
import { useEditorAppStore } from "./editor-app.store";

const WORKSPACE_A = "editor-app-test-a";
const WORKSPACE_B = "editor-app-test-b";

function editorBuffer(
  id: string,
  content: string,
  options: { isDirty?: boolean; isPreview?: boolean; isVirtual?: boolean; path?: string } = {},
): EditorContent {
  const path =
    options.path ?? `${options.isVirtual === false ? "C:/workspace" : "virtual:"}/${id}.txt`;
  return {
    id,
    type: "editor",
    path,
    name: `${id}.txt`,
    content,
    savedContent: options.isDirty ? `${content}-saved` : content,
    isDirty: options.isDirty ?? false,
    isVirtual: options.isVirtual ?? true,
    isPinned: false,
    isPreview: options.isPreview ?? false,
    isActive: true,
    tokens: [],
  };
}

function setWorkspaceBuffers(
  workspaceId: string,
  buffers: EditorContent[],
  activeBufferId: string,
) {
  useBufferStore.getStore(workspaceId).setState({ buffers, activeBufferId });
}

function getEditorBuffer(workspaceId: string, bufferId: string): EditorContent {
  const buffer = getBufferById(useBufferStore.getStore(workspaceId).getState().buffers, bufferId);
  if (!buffer || buffer.type !== "editor") {
    throw new Error(`Expected editor buffer: ${bufferId}`);
  }
  return buffer;
}

beforeEach(() => {
  workspaceRuntimeRegistry.resetForTests();
  workspaceRuntimeRegistry.ensureWorkspace({ id: WORKSPACE_A, name: "Workspace A" }, "ready");
  workspaceRuntimeRegistry.ensureWorkspace({ id: WORKSPACE_B, name: "Workspace B" }, "ready");
});

describe("workspace-scoped editor actions", () => {
  test("routes content changes to the source workspace", async () => {
    setWorkspaceBuffers(
      WORKSPACE_A,
      [editorBuffer("a", "A original", { isVirtual: false })],
      "a",
    );
    setWorkspaceBuffers(WORKSPACE_B, [editorBuffer("b", "B original")], "b");
    workspaceRuntimeRegistry.activateWorkspace({ id: WORKSPACE_B, name: "Workspace B" }, "ready");

    await useEditorAppStore
      .getStore(WORKSPACE_A)
      .getState()
      .actions.handleContentChange("a", "A edited");

    expect(getEditorBuffer(WORKSPACE_A, "a").content).toBe("A edited");
    expect(getEditorBuffer(WORKSPACE_A, "a").contentRevision).toBe(1);
    expect(getEditorBuffer(WORKSPACE_A, "a").documentLifecycle).toEqual({
      status: "dirty",
      revision: 1,
      savedRevision: 0,
    });
    expect(getEditorBuffer(WORKSPACE_B, "b").content).toBe("B original");
  });

  test("routes content changes to the emitting buffer when another buffer is active", async () => {
    setWorkspaceBuffers(
      WORKSPACE_A,
      [editorBuffer("source", "Source original"), editorBuffer("active", "Active original")],
      "active",
    );

    await useEditorAppStore
      .getStore(WORKSPACE_A)
      .getState()
      .actions.handleContentChange("source", "Source edited");

    expect(getEditorBuffer(WORKSPACE_A, "source").content).toBe("Source edited");
    expect(getEditorBuffer(WORKSPACE_A, "active").content).toBe("Active original");
  });

  test("promotes an edited preview buffer before another preview can replace it", async () => {
    setWorkspaceBuffers(
      WORKSPACE_A,
      [editorBuffer("preview", "Original", { isPreview: true, isVirtual: false })],
      "preview",
    );

    await useEditorAppStore
      .getStore(WORKSPACE_A)
      .getState()
      .actions.handleContentChange("preview", "Edited");

    const preview = getEditorBuffer(WORKSPACE_A, "preview");
    expect(preview.content).toBe("Edited");
    expect(preview.isPreview).toBe(false);
    expect(preview.isDirty).toBe(true);
  });

  test("keeps remote edits dirty until the remote write succeeds", async () => {
    setWorkspaceBuffers(
      WORKSPACE_A,
      [
        editorBuffer("remote", "Original", {
          isVirtual: false,
          path: "remote://connection/project/file.txt",
        }),
      ],
      "remote",
    );

    await useEditorAppStore
      .getStore(WORKSPACE_A)
      .getState()
      .actions.handleContentChange("remote", "Edited");

    const remoteBuffer = getEditorBuffer(WORKSPACE_A, "remote");
    expect(remoteBuffer.content).toBe("Edited");
    expect(remoteBuffer.isDirty).toBe(true);
  });

  test("saves only the explicitly targeted workspace buffer", async () => {
    setWorkspaceBuffers(WORKSPACE_A, [editorBuffer("a", "A edited", { isDirty: true })], "a");
    setWorkspaceBuffers(WORKSPACE_B, [editorBuffer("b", "B edited", { isDirty: true })], "b");
    workspaceRuntimeRegistry.activateWorkspace({ id: WORKSPACE_B, name: "Workspace B" }, "ready");

    const result = await useEditorAppStore.getStore(WORKSPACE_A).getState().actions.handleSave("a");

    const workspaceABuffer = getEditorBuffer(WORKSPACE_A, "a");
    const workspaceBBuffer = getEditorBuffer(WORKSPACE_B, "b");
    expect(result).toBe("saved");
    expect(workspaceABuffer.isDirty).toBe(false);
    expect(workspaceBBuffer.isDirty).toBe(true);
  });

  test("keeps failed saves dirty and reports the failure", async () => {
    const saveFailureToast = spyOn(toast, "error").mockImplementation(() => "test-toast");
    const expectedParseError = spyOn(console, "error").mockImplementation(() => undefined);
    setWorkspaceBuffers(
      WORKSPACE_A,
      [
        editorBuffer("settings", "not valid json", {
          isDirty: true,
          path: "settings://user-settings.json",
        }),
      ],
      "settings",
    );

    try {
      const result = await useEditorAppStore
        .getStore(WORKSPACE_A)
        .getState()
        .actions.handleSave("settings");

      expect(result).toBe("failed");
      expect(getEditorBuffer(WORKSPACE_A, "settings").isDirty).toBe(true);
      expect(saveFailureToast).toHaveBeenCalledTimes(1);
      expect(saveFailureToast.mock.calls[0]?.[0]).toContain("settings.txt");
    } finally {
      saveFailureToast.mockRestore();
      expectedParseError.mockRestore();
    }
  });
});
