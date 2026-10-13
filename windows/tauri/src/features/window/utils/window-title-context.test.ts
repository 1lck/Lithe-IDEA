import { expect, test } from "bun:test";
import type { EditorContent, PaneContent } from "@/features/panes/types/pane-content.types";
import type { PaneGroup, PaneSplit } from "@/features/panes/types/pane.types";
import { WELCOME_WORKSPACE_ID } from "@/features/workspace/types/workspace-runtime.types";
import {
  buildWindowTitleContext,
  getWindowTitleFileName,
  type WindowTitlePaneState,
} from "./window-title-context";

function editor(id: string, name = "Application.java", overrides: Partial<EditorContent> = {}): EditorContent {
  return {
    id,
    type: "editor",
    name,
    path: `C:/projects/demo/${name}`,
    content: "",
    savedContent: "",
    isDirty: false,
    isVirtual: false,
    isPinned: false,
    isPreview: false,
    isActive: false,
    tokens: [],
    ...overrides,
  };
}

function pane(id: string, activeBufferId: string | null): PaneGroup {
  return { id, type: "group", activeBufferId, bufferIds: activeBufferId ? [activeBufferId] : [] };
}

function layout(activeBufferId: string | null): WindowTitlePaneState {
  return { root: pane("main", activeBufferId), bottomRoot: pane("bottom", null), activePaneId: "main" };
}

const projects = [{ id: "demo", name: "demo", displayAlias: "后端", path: "C:/projects/demo" }];

test("includes all project display labels but reads the file from the active workspace", () => {
  expect(buildWindowTitleContext({
    projects: [...projects, { id: "background", name: "demo", path: "D:/samples/demo" }],
    workspaceId: "demo",
    status: "ready",
    panes: layout("file"),
    buffers: { buffers: [editor("file")] },
  })).toEqual({
    projects: [
      { workspaceId: "background", displayName: "demo", path: "D:/samples/demo" },
      { workspaceId: "demo", displayName: "demo (后端)", path: "C:/projects/demo" },
    ],
    activeWorkspaceId: "demo",
    fileName: "Application.java",
  });
});

test("uses the active split rather than the first or last opened editor", () => {
  const root: PaneSplit = {
    id: "split", type: "split", direction: "horizontal", sizes: [0.5, 0.5],
    children: [pane("left", "first"), pane("right", "second")],
  };
  const snapshot = {
    projects, workspaceId: "demo", status: "ready" as const,
    panes: { root, bottomRoot: pane("bottom", null), activePaneId: "left" },
    buffers: { buffers: [editor("first", "First.java"), editor("second", "Second.java")] },
  };
  expect(buildWindowTitleContext(snapshot).fileName).toBe("First.java");
  expect(buildWindowTitleContext({ ...snapshot, panes: { ...snapshot.panes, activePaneId: "right" } }).fileName)
    .toBe("Second.java");
});

test("clears the file name when a bottom tool pane is active", () => {
  const terminal = { ...editor("tool"), type: "terminal", sessionId: "session" } as PaneContent;
  expect(buildWindowTitleContext({
    projects, workspaceId: "demo", status: "ready",
    panes: { root: pane("main", "file"), bottomRoot: pane("bottom", "tool"), activePaneId: "bottom" },
    buffers: { buffers: [editor("file"), terminal] },
  }).fileName).toBeNull();
});

test("keeps only the project name while opening or recovering from an error", () => {
  for (const status of ["opening", "error", undefined] as const) {
    const context = buildWindowTitleContext({
      projects, workspaceId: "demo", status,
      panes: layout("file"), buffers: { buffers: [editor("file")] },
    });
    expect(context.activeWorkspaceId).toBe("demo");
    expect(context.fileName).toBeNull();
  }
});

test("supports standalone files in the welcome workspace and an empty welcome page", () => {
  const snapshot = {
    projects: [], workspaceId: WELCOME_WORKSPACE_ID, status: "empty" as const,
    panes: layout("file"), buffers: { buffers: [editor("file", "notes.md")] },
  };
  expect(buildWindowTitleContext(snapshot)).toEqual({ projects: [], activeWorkspaceId: null, fileName: "notes.md" });
  expect(buildWindowTitleContext({ ...snapshot, panes: layout(null) }).fileName).toBeNull();
});

test("ignores missing panes, closed buffers and runtimes no longer represented by a project", () => {
  const snapshot = {
    projects, workspaceId: "demo", status: "ready" as const,
    panes: layout("file"), buffers: { buffers: [editor("file")] },
  };
  expect(buildWindowTitleContext({ ...snapshot, buffers: { buffers: [] } }).fileName).toBeNull();
  expect(buildWindowTitleContext({ ...snapshot, panes: { ...snapshot.panes, activePaneId: "closed" } }).fileName).toBeNull();
  expect(buildWindowTitleContext({ ...snapshot, workspaceId: "removed" }).fileName).toBeNull();
});

test("uses source file names for Markdown, HTML and CSV previews", () => {
  for (const type of ["markdownPreview", "htmlPreview", "csvPreview"] as const) {
    const buffer = { ...editor("preview", "预览"), type, sourceFilePath: "D:\\demo\\中文 😀.md" };
    expect(getWindowTitleFileName(buffer)).toBe("中文 😀.md");
    expect(getWindowTitleFileName({ ...buffer, sourceFilePath: "preview://generated" })).toBeNull();
  }
});

test("shows real local files including UNC paths and rejects virtual and remote editors", () => {
  for (const type of ["image", "pdf", "binary"] as const) {
    expect(getWindowTitleFileName({ ...editor("file", "报告.pdf"), type, path: "\\\\server\\share\\报告.pdf" }))
      .toBe("报告.pdf");
  }
  expect(getWindowTitleFileName(editor("file", "untitled", { isVirtual: true }))).toBeNull();
  expect(getWindowTitleFileName(editor("file", "remote.java", { path: "remote://server/remote.java" }))).toBeNull();
  expect(getWindowTitleFileName(editor("file", "wsl.java", { path: "\\\\wsl.localhost\\Ubuntu\\wsl.java" }))).toBeNull();
});

test("does not expose file names for tools, diffs or generated documents", () => {
  for (const type of ["globalSearch", "diff", "markdownDocument", "webViewer", "externalEditor"] as const) {
    expect(getWindowTitleFileName({ ...editor("tool"), type } as PaneContent)).toBeNull();
  }
});
