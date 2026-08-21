import { describe, expect, test } from "bun:test";
import type { EditorContent } from "@/features/panes/types/pane-content.types";
import {
  editorBufferSurfacesEqual,
  getEditorBufferSurface,
} from "./buffer-metadata";

function editorBuffer(overrides: Partial<EditorContent> = {}): EditorContent {
  return {
    id: "buffer-1",
    type: "editor",
    path: "src/main.ts",
    name: "main.ts",
    isPinned: false,
    isPreview: false,
    isActive: true,
    content: "const value = 1;",
    savedContent: "const value = 1;",
    isDirty: false,
    isVirtual: false,
    tokens: [],
    contentRevision: 0,
    ...overrides,
  };
}

describe("editor buffer surface", () => {
  test("omits document text so typing does not change the selected surface", () => {
    const before = getEditorBufferSurface(editorBuffer({ content: "a" }));
    const after = getEditorBufferSurface(editorBuffer({ content: "ab", isDirty: true }));
    expect(editorBufferSurfacesEqual(before, after)).toBe(true);
  });

  test("treats external contentRevision bumps as a new surface", () => {
    const before = getEditorBufferSurface(editorBuffer({ contentRevision: 1 }));
    const after = getEditorBufferSurface(
      editorBuffer({ content: "from disk", contentRevision: 2 }),
    );
    expect(editorBufferSurfacesEqual(before, after)).toBe(false);
  });

  test("treats a missing buffer as a null surface without throwing", () => {
    expect(getEditorBufferSurface(null)).toBeNull();
    expect(editorBufferSurfacesEqual(null, getEditorBufferSurface(editorBuffer()))).toBe(false);
  });
});
