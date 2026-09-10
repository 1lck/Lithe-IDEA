import { describe, expect, test } from "bun:test";
import type {
  EditorContent,
  MarkdownPreviewContent,
} from "@/features/panes/types/pane-content.types";
import { isMarkdownEditorBuffer, isMarkdownPreviewableFile } from "./previewable";

function editorBuffer(overrides: Partial<EditorContent> = {}): EditorContent {
  return {
    id: "buffer-1",
    type: "editor",
    path: "src/main.ts",
    name: "main.ts",
    isPinned: false,
    isPreview: false,
    isActive: true,
    content: "# Heading",
    savedContent: "# Heading",
    isDirty: false,
    isVirtual: false,
    tokens: [],
    contentRevision: 0,
    ...overrides,
  };
}

describe("markdown previewable", () => {
  test("matches markdown file extensions", () => {
    expect(isMarkdownPreviewableFile("docs/readme.md")).toBe(true);
    expect(isMarkdownPreviewableFile("docs/notes.markdown")).toBe(true);
    expect(isMarkdownPreviewableFile("docs/analysis.RMD")).toBe(true);
    expect(isMarkdownPreviewableFile("src/main.ts")).toBe(false);
  });

  test("identifies markdown editor buffers as switchable", () => {
    expect(isMarkdownEditorBuffer(editorBuffer({ path: "docs/readme.md" }))).toBe(true);
    expect(isMarkdownEditorBuffer(editorBuffer({ path: "docs/notes.markdown" }))).toBe(true);
    expect(isMarkdownEditorBuffer(editorBuffer({ path: "docs/analysis.rmd" }))).toBe(true);
    expect(isMarkdownEditorBuffer(editorBuffer({ path: "src/main.ts" }))).toBe(false);
  });

  test("rejects missing buffers and non-editor buffer types", () => {
    expect(isMarkdownEditorBuffer(null)).toBe(false);
    const previewBuffer: MarkdownPreviewContent = {
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
    expect(isMarkdownEditorBuffer(previewBuffer)).toBe(false);
  });
});
