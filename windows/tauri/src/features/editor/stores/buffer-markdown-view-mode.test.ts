import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import type {
  EditorContent,
  MarkdownViewMode,
  PaneContent,
} from "@/features/panes/types/pane-content.types";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { getBufferById } from "../utils/buffer-index";
import { useBufferStore } from "./buffer.store";
import { useEditorStateStore } from "./state.store";

const WORKSPACE = "markdown-view-mode-test";

function editorBuffer(id: string, path: string): EditorContent {
  return {
    id,
    type: "editor",
    path,
    name: `${id}.md`,
    content: "# Heading",
    savedContent: "# Heading",
    isDirty: false,
    isVirtual: false,
    isPinned: false,
    isPreview: false,
    isActive: true,
    tokens: [],
  };
}

function setBuffers(buffers: PaneContent[], activeBufferId: string) {
  useBufferStore.getStore(WORKSPACE).setState({ buffers, activeBufferId });
}

function bufferById(bufferId: string): PaneContent | null {
  return getBufferById(useBufferStore.getStore(WORKSPACE).getState().buffers, bufferId);
}

function editorMode(bufferId: string): MarkdownViewMode | undefined {
  const buffer = bufferById(bufferId);
  return buffer?.type === "editor" ? buffer.markdownViewMode : undefined;
}

beforeEach(() => {
  workspaceRuntimeRegistry.resetForTests();
  workspaceRuntimeRegistry.ensureWorkspace({ id: WORKSPACE, name: "Workspace" }, "ready");
});

afterEach(() => {
  useBufferStore.getStore(WORKSPACE).setState({ buffers: [], activeBufferId: null });
});

describe("setMarkdownViewMode", () => {
  test("late restore preserves edits and their dirty lifecycle", () => {
    const buffer = editorBuffer("pending", "docs/pending.md");
    buffer.loadState = "loading";
    buffer.content = "new edit";
    buffer.savedContent = "old content";
    buffer.contentRevision = 1;
    buffer.isDirty = true;
    buffer.documentLifecycle = { status: "dirty", revision: 1, savedRevision: 0 };
    setBuffers([buffer], buffer.id);
    useBufferStore.getStore(WORKSPACE).getState().actions
      .replaceRestoredBufferContent(buffer.id, "stale disk content", "markdown");
    const restored = bufferById(buffer.id) as EditorContent;
    expect(restored.content).toBe("new edit");
    expect(restored.savedContent).toBe("old content");
    expect(restored.isDirty).toBe(true);
    expect(restored.documentLifecycle).toEqual(buffer.documentLifecycle);
    expect(restored.loadState).toBe("loaded");
  });

  test("stores the display mode on a markdown editor buffer", () => {
    setBuffers([editorBuffer("readme", "docs/readme.md")], "readme");
    const { setMarkdownViewMode } = useBufferStore.getStore(WORKSPACE).getState().actions;

    setMarkdownViewMode("readme", "split");
    expect(editorMode("readme")).toBe("split");

    setMarkdownViewMode("readme", "preview");
    expect(editorMode("readme")).toBe("preview");

    setMarkdownViewMode("readme", "source");
    expect(editorMode("readme")).toBe("source");
  });

  test("does not leak the mode between buffers", () => {
    setBuffers(
      [editorBuffer("readme", "docs/readme.md"), editorBuffer("guide", "docs/guide.md")],
      "readme",
    );
    const { setMarkdownViewMode } = useBufferStore.getStore(WORKSPACE).getState().actions;

    setMarkdownViewMode("readme", "preview");

    expect(editorMode("guide")).toBeUndefined();
  });

  test("ignores buffers that are not markdown editor buffers", () => {
    const previewBuffer: PaneContent = {
      id: "preview-1",
      type: "markdownPreview",
      path: "docs/readme.md:preview",
      name: "readme.md (Preview)",
      isPinned: false,
      isPreview: false,
      isActive: true,
      content: "# Heading",
      sourceFilePath: "docs/readme.md",
    };
    setBuffers([previewBuffer], "preview-1");
    const { setMarkdownViewMode } = useBufferStore.getStore(WORKSPACE).getState().actions;

    setMarkdownViewMode("preview-1", "preview");

    const stored = bufferById("preview-1");
    expect(stored?.type === "markdownPreview" && "markdownViewMode" in stored).toBe(false);
  });

  test("caches persisted view state while a restored placeholder is unloaded", () => {
    const editorState = {
      cursor: { line: 6, column: 4, offset: 42 },
      scrollTop: 180,
      scrollLeft: 12,
    };
    const bufferStore = useBufferStore.getStore(WORKSPACE);
    const bufferId = bufferStore.getState().actions.createRestoredBufferMetadata({
      path: "src/main.ts",
      name: "main.ts",
      isPinned: false,
      isPreview: false,
      editorState,
    });

    expect(useEditorStateStore.getState().actions.getCachedViewState(bufferId)).toEqual(editorState);
    const restoredBuffer = bufferById(bufferId);
    expect(restoredBuffer?.type === "editor" ? restoredBuffer.loadState : undefined).toBe(
      "unloaded",
    );
    useEditorStateStore.getState().actions.clearPositionCache(bufferId);
  });
});
