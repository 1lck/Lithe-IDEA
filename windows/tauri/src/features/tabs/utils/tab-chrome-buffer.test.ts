import { describe, expect, test } from "bun:test";
import { tabChromeBuffersEqual, toTabChromeBuffer } from "./tab-chrome-buffer";
import type { EditorContent } from "@/features/panes/types/pane-content.types";

function editorBuffer(overrides: Partial<EditorContent> = {}): EditorContent {
  return {
    id: "buffer-1",
    type: "editor",
    path: "src/main.ts",
    name: "main.ts",
    isPinned: false,
    isPreview: false,
    isActive: true,
    content: "lots of file text",
    savedContent: "lots of file text",
    isDirty: true,
    isVirtual: false,
    tokens: [{ start: 0, end: 4, token_type: "keyword", class_name: "k" }],
    ...overrides,
  };
}

describe("toTabChromeBuffer", () => {
  test("drops editor content so tab chrome does not rerender on typing", () => {
    const buffer = editorBuffer();

    expect(toTabChromeBuffer(buffer)).toEqual({
      ...buffer,
      content: "",
      savedContent: "",
      tokens: [],
    });
  });

  test("treats content-only updates as equal tab chrome", () => {
    const before = [toTabChromeBuffer(editorBuffer({ content: "a" }))];
    const after = [toTabChromeBuffer(editorBuffer({ content: "ab" }))];
    expect(tabChromeBuffersEqual(before, after)).toBe(true);
  });

  test("rerenders tabs when dirty metadata changes", () => {
    const before = [toTabChromeBuffer(editorBuffer({ isDirty: false }))];
    const after = [toTabChromeBuffer(editorBuffer({ isDirty: true }))];
    expect(tabChromeBuffersEqual(before, after)).toBe(false);
  });

  test("does not throw when comparing against a missing previous snapshot", () => {
    expect(tabChromeBuffersEqual(undefined, [toTabChromeBuffer(editorBuffer())])).toBe(false);
  });
});
