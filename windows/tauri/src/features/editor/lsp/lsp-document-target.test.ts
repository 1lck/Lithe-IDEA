import { describe, expect, test } from "bun:test";
import type { EditorContent } from "@/features/panes/types/pane-content.types";
import {
  lspDocumentRequestArgs,
  lspDocumentTargetForEditor,
  lspDocumentTargetForEditorPath,
  lspSessionFilePath,
} from "./lsp-document-target";

function editor(overrides: Partial<EditorContent>): EditorContent {
  return {
    id: "buffer-1",
    type: "editor",
    path: "C:/work/Main.java",
    name: "Main.java",
    content: "class Main {}",
    savedContent: "class Main {}",
    isDirty: false,
    isVirtual: false,
    isPinned: false,
    isPreview: false,
    isActive: true,
    tokens: [],
    ...overrides,
  };
}

describe("LSP document targets", () => {
  test("uses a physical editor path as its session and document identity", () => {
    const target = lspDocumentTargetForEditor(editor({}));

    expect(target).toEqual({
      filePath: "C:/work/Main.java",
      documentUri: undefined,
      sessionFilePath: undefined,
      languageId: "java",
    });
    expect(lspSessionFilePath(target)).toBe("C:/work/Main.java");
  });

  test("preserves an opaque virtual URI and reuses its source-file session", () => {
    const target = lspDocumentTargetForEditor(
      editor({
        path: "jdt://contents/java.base/java/lang/String.class?=demo",
        name: "String.java",
        isVirtual: true,
        readOnly: true,
        language: "java",
        lspDocument: {
          documentUri: "jdt://contents/java.base/java/lang/String.class?=demo",
          sessionFilePath: "C:/work/Main.java",
          languageId: "java",
        },
      }),
    );

    expect(lspDocumentRequestArgs(target)).toEqual({
      filePath: "jdt://contents/java.base/java/lang/String.class?=demo",
      sessionFilePath: "C:/work/Main.java",
      documentUri: "jdt://contents/java.base/java/lang/String.class?=demo",
    });
    expect(target.languageId).toBe("java");
  });

  test("prefers an explicit language override over the provider binding", () => {
    const target = lspDocumentTargetForEditor(
      editor({
        languageOverride: "kotlin",
        lspDocument: {
          documentUri: "provider://document",
          sessionFilePath: "C:/work/Main.java",
          languageId: "java",
        },
      }),
    );

    expect(target.languageId).toBe("kotlin");
  });

  test("resolves the provider target from the backing virtual editor buffer", () => {
    const virtual = editor({
      path: "jdt://contents/java.base/java/lang/String.class?=demo",
      isVirtual: true,
      lspDocument: {
        documentUri: "jdt://contents/java.base/java/lang/String.class?=demo",
        sessionFilePath: "C:/work/Main.java",
        languageId: "java",
      },
    });

    expect(lspDocumentTargetForEditorPath([virtual], virtual.path)).toEqual({
      filePath: virtual.path,
      documentUri: virtual.path,
      sessionFilePath: "C:/work/Main.java",
      languageId: "java",
    });
    expect(lspDocumentTargetForEditorPath([virtual], "C:/work/Missing.java")).toBeNull();
  });
});
