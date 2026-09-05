import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import type {
  EditorContent,
  MarkdownViewMode,
  PaneContent,
} from "@/features/panes/types/pane-content.types";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { getBufferById } from "../utils/buffer-index";
import { useBufferStore } from "./buffer.store";

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
});
