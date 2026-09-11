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

  test("carries the markdown view mode so switching modes re-renders the editor", () => {
    const before = getEditorBufferSurface(editorBuffer({ path: "docs/readme.md" }));
    const after = getEditorBufferSurface(
      editorBuffer({ path: "docs/readme.md", markdownViewMode: "preview" }),
    );
    expect(before?.markdownViewMode).toBeUndefined();
    expect(after?.markdownViewMode).toBe("preview");
    expect(editorBufferSurfacesEqual(before, after)).toBe(false);
    expect(
      editorBufferSurfacesEqual(
        getEditorBufferSurface(editorBuffer({ markdownViewMode: "preview" })),
        getEditorBufferSurface(editorBuffer({ markdownViewMode: "preview" })),
      ),
    ).toBe(true);
  });

  test("never reports a markdown view mode for preview buffers", () => {
    const previewBuffer = {
      id: "preview-1",
      type: "markdownPreview" as const,
      path: "docs/readme.md:preview",
      name: "readme.md (Preview)",
      isPinned: false,
      isPreview: false,
      isActive: true,
      content: "",
      sourceFilePath: "docs/readme.md",
    };
    expect(getEditorBufferSurface(previewBuffer)?.markdownViewMode).toBeUndefined();
  });

  test("preserves virtual document language and LSP binding metadata", () => {
    const surface = getEditorBufferSurface(
      editorBuffer({
        path: "jdt://contents/java.base/java/lang/String.class?=demo",
        language: "java",
        lspDocument: {
          documentUri: "jdt://contents/java.base/java/lang/String.class?=demo",
          sessionFilePath: "C:/work/Main.java",
          languageId: "java",
        },
      }),
    );

    expect(surface).toMatchObject({
      language: "java",
      lspDocument: {
        documentUri: "jdt://contents/java.base/java/lang/String.class?=demo",
        sessionFilePath: "C:/work/Main.java",
        languageId: "java",
      },
    });
  });

  test("treats virtual document binding changes as a new surface", () => {
    const before = getEditorBufferSurface(
      editorBuffer({
        language: "java",
        lspDocument: {
          documentUri: "jdt://contents/java.base/java/lang/String.class?=demo",
          sessionFilePath: "C:/work/Old.java",
          languageId: "java",
        },
      }),
    );
    const after = getEditorBufferSurface(
      editorBuffer({
        language: "java",
        lspDocument: {
          documentUri: "jdt://contents/java.base/java/lang/String.class?=demo",
          sessionFilePath: "C:/work/New.java",
          languageId: "java",
        },
      }),
    );

    expect(editorBufferSurfacesEqual(before, after)).toBe(false);
  });

  test("treats a missing buffer as a null surface without throwing", () => {
    expect(getEditorBufferSurface(null)).toBeNull();
    expect(editorBufferSurfacesEqual(null, getEditorBufferSurface(editorBuffer()))).toBe(false);
  });
});
