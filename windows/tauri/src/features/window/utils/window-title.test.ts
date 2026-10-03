import { describe, expect, test } from "bun:test";
import type {
  EditorContent,
  PaneContent,
  TerminalContent,
} from "@/features/panes/types/pane-content.types";
import {
  composeWindowTitle,
  DEFAULT_WINDOW_TITLE,
  getActiveFileTitleSegment,
} from "./window-title";

function editorBuffer(overrides: Partial<EditorContent> = {}): EditorContent {
  return {
    id: "buffer_editor",
    type: "editor",
    path: "D:/project/Lithe-IDEA/README.md",
    name: "README.md",
    isPinned: false,
    isPreview: false,
    isActive: true,
    content: "",
    savedContent: "",
    isDirty: false,
    isVirtual: false,
    tokens: [],
    ...overrides,
  };
}

function terminalBuffer(): TerminalContent {
  return {
    id: "buffer_terminal",
    type: "terminal",
    // Terminal buffers carry a synthetic scheme path and must not count as an open file.
    path: "terminal://session-1",
    name: "Terminal",
    isPinned: false,
    isPreview: false,
    isActive: true,
    sessionId: "session-1",
  };
}

describe("getActiveFileTitleSegment", () => {
  test("returns the active file buffer's name", () => {
    const buffers: readonly PaneContent[] = [
      editorBuffer({ id: "buffer_a", path: "D:/project/Lithe-IDEA/src/main.rs", name: "main.rs" }),
    ];

    expect(getActiveFileTitleSegment(buffers, "buffer_a")).toBe("main.rs");
  });

  test("returns null for tool tabs without a backing file so the title keeps the project only", () => {
    const buffers: readonly PaneContent[] = [terminalBuffer()];

    expect(getActiveFileTitleSegment(buffers, "buffer_terminal")).toBeNull();
  });

  test("returns null for virtual editor buffers and for a missing active buffer", () => {
    const buffers: readonly PaneContent[] = [
      editorBuffer({
        id: "buffer_virtual",
        path: "jdt://contents/Foo.class",
        name: "Foo.class",
        isVirtual: true,
      }),
    ];

    expect(getActiveFileTitleSegment(buffers, "buffer_virtual")).toBeNull();
    expect(getActiveFileTitleSegment(buffers, null)).toBeNull();
    expect(getActiveFileTitleSegment(buffers, "buffer_missing")).toBeNull();
  });

  test("returns null when the buffer name is blank", () => {
    const buffers: readonly PaneContent[] = [editorBuffer({ id: "buffer_blank", name: "   " })];

    expect(getActiveFileTitleSegment(buffers, "buffer_blank")).toBeNull();
  });
});

describe("composeWindowTitle", () => {
  test("composes project and active file with the IntelliJ-style separator", () => {
    expect(composeWindowTitle({ name: "Lithe-IDEA" }, "main.rs")).toBe("Lithe-IDEA – main.rs");
  });

  test("shows only the project name when the editor area has no file open", () => {
    expect(composeWindowTitle({ name: "Lithe-IDEA" }, null)).toBe("Lithe-IDEA");
  });

  test("appends the display alias to the project segment when defined", () => {
    expect(composeWindowTitle({ name: "demo", displayAlias: "upstream" }, "a.ts")).toBe(
      "demo (upstream) – a.ts",
    );
  });

  test("falls back to the bundled product name without a project", () => {
    expect(composeWindowTitle(null, "a.ts")).toBe("a.ts");
    expect(composeWindowTitle(null, null)).toBe(DEFAULT_WINDOW_TITLE);
    expect(composeWindowTitle(undefined, undefined)).toBe("Lithe");
  });

  test("drops a blank project label instead of leaving an empty leading segment", () => {
    expect(composeWindowTitle({ name: "   " }, "a.ts")).toBe("a.ts");
  });
});
