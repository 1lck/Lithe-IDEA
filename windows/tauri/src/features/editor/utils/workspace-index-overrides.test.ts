import { describe, expect, test } from "bun:test";
import type { EditorContent, PaneContent } from "@/features/panes/types/pane-content.types";
import {
  collectUnsavedIndexTextOverrides,
  didIndexedEditorTextChange,
} from "./workspace-index-overrides";

const ROOT = "C:/work";
const isJava = (path: string) => path.endsWith(".java");
const relative = (path: string) => path.slice(ROOT.length + 1);

function editor(path: string, content: string, overrides: Partial<EditorContent> = {}): PaneContent {
  return {
    id: path,
    type: "editor",
    path,
    name: path.split("/").pop()!,
    isPinned: false,
    isPreview: false,
    isActive: false,
    content,
    savedContent: content,
    isDirty: false,
    isVirtual: false,
    tokens: [],
    ...overrides,
  } as EditorContent;
}

describe("workspace index text overrides", () => {
  test("sends only unsaved indexed editor text", () => {
    const buffers = [
      editor(`${ROOT}/Clean.java`, "class Clean {}"),
      editor(`${ROOT}/Edited.java`, "class Edited { int x; }", { savedContent: "class Edited {}" }),
      editor(`${ROOT}/notes.md`, "draft", { savedContent: "" }),
      editor(`${ROOT}/Virtual.java`, "class Virtual {}", { savedContent: "", isVirtual: true }),
    ];

    expect(collectUnsavedIndexTextOverrides(buffers, isJava, relative)).toEqual({
      "Edited.java": "class Edited { int x; }",
    });
  });

  test("opening, loading, saving, and closing clean files do not change the indexed text", () => {
    const loading = editor(`${ROOT}/A.java`, "", { loadState: "loading" });
    const loaded = editor(`${ROOT}/A.java`, "class A {}", { loadState: "loaded" });
    const opened = [loaded, editor(`${ROOT}/B.java`, "class B {}")];
    const edited = editor(`${ROOT}/A.java`, "class A { }", { savedContent: "class A {}" });
    const saved = editor(`${ROOT}/A.java`, "class A { }");

    expect(didIndexedEditorTextChange([loading], [], isJava)).toBe(false);
    expect(didIndexedEditorTextChange([loaded], [loading], isJava)).toBe(false);
    expect(didIndexedEditorTextChange(opened, [loaded], isJava)).toBe(false);
    expect(didIndexedEditorTextChange([saved], [edited], isJava)).toBe(false);
    expect(didIndexedEditorTextChange([], [loaded], isJava)).toBe(false);
  });

  test("editing, opening restored unsaved text, and discarding edits change the indexed text", () => {
    const clean = editor(`${ROOT}/A.java`, "class A {}");
    const edited = editor(`${ROOT}/A.java`, "class A { }", { savedContent: "class A {}" });

    expect(didIndexedEditorTextChange([edited], [clean], isJava)).toBe(true);
    expect(didIndexedEditorTextChange([edited], [], isJava)).toBe(true);
    expect(didIndexedEditorTextChange([], [edited], isJava)).toBe(true);
  });

  test("ignores unrelated buffers and unchanged snapshots", () => {
    const buffers = [editor(`${ROOT}/README.md`, "a")];
    const typed = [editor(`${ROOT}/README.md`, "ab", { savedContent: "a" })];

    expect(didIndexedEditorTextChange(typed, buffers, isJava)).toBe(false);
    expect(didIndexedEditorTextChange(buffers, buffers, isJava)).toBe(false);
  });
});
