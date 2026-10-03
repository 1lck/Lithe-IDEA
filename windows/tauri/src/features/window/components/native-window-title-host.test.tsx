import { afterEach, beforeEach, expect, mock, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import type {
  EditorContent,
  PaneContent,
  TerminalContent,
} from "@/features/panes/types/pane-content.types";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { WorkspaceStoreScopeContext } from "@/features/workspace/stores/create-workspace-scoped-store";
import { installHappyDom } from "@/test-utils/happy-dom";

const appliedTitles: string[] = [];
const setTitle = mock(async (_title: string) => {});

// The host reads the native window inside an effect; patch the Tauri window
// module so a missing __TAURI_INTERNALS__ never reaches the test. Keep the
// real exports because sibling Tauri modules (webviewWindow) re-import them.
const actualWindowModule = await import("@tauri-apps/api/window");
mock.module("@tauri-apps/api/window", () => ({
  ...actualWindowModule,
  getCurrentWindow: () => ({
    setTitle: (title: string) => {
      appliedTitles.push(title);
      return setTitle(title);
    },
  }),
}));

const { NativeWindowTitleHost } = await import("./native-window-title-host");
const { useWorkspaceTabsStore } = await import("../stores/workspace-tabs.store");
const { useBufferStore } = await import("@/features/editor/stores/buffer.store");

const WORKSPACE = "native-window-title-test";

function editorBuffer(id: string, name: string): EditorContent {
  return {
    id,
    type: "editor",
    path: `D:/project/demo/src/${name}`,
    name,
    content: "",
    savedContent: "",
    isDirty: false,
    isVirtual: false,
    isPinned: false,
    isPreview: false,
    isActive: true,
    tokens: [],
  };
}

function terminalBuffer(id: string): TerminalContent {
  return {
    id,
    type: "terminal",
    path: `terminal://${id}`,
    name: "Terminal",
    isPinned: false,
    isPreview: false,
    isActive: true,
    sessionId: id,
  };
}

function setActiveProjectTab(name: string) {
  useWorkspaceTabsStore.setState({
    projectTabs: [
      { id: `tab-${name}`, name, path: `D:/project/${name}`, isActive: true, lastOpened: 1 },
    ],
  });
}

async function renderHost(container: HTMLElement): Promise<Root> {
  const root = createRoot(container);
  await act(async () => {
    root.render(
      <WorkspaceStoreScopeContext.Provider value={WORKSPACE}>
        <NativeWindowTitleHost />
      </WorkspaceStoreScopeContext.Provider>,
    );
  });
  return root;
}

beforeEach(() => {
  workspaceRuntimeRegistry.resetForTests();
  workspaceRuntimeRegistry.ensureWorkspace({ id: WORKSPACE, name: "Workspace" }, "ready");
  useWorkspaceTabsStore.setState({ projectTabs: [] });
  appliedTitles.length = 0;
  setTitle.mockClear();
});

afterEach(() => {
  useWorkspaceTabsStore.setState({ projectTabs: [] });
  useBufferStore.getStore(WORKSPACE).setState({ buffers: [], activeBufferId: null });
});

test("taskbar title shows project and active file, then project only, without duplicate updates", async () => {
  const restoreDom = installHappyDom();
  const actEnvironment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousActEnvironment = actEnvironment.IS_REACT_ACT_ENVIRONMENT;
  const container = document.createElement("div");
  let root: Root | undefined;

  try {
    actEnvironment.IS_REACT_ACT_ENVIRONMENT = true;
    document.body.append(container);
    root = await renderHost(container);
    // No project and no open file: keep the bundled product name.
    expect(appliedTitles).toEqual(["Lithe"]);

    // Project open, editor area empty: project name only.
    await act(async () => {
      setActiveProjectTab("demo");
    });
    expect(appliedTitles[appliedTitles.length - 1]).toBe("demo");

    // File opened in the editor area: `project – file` like the taskbar preview.
    await act(async () => {
      useBufferStore.getStore(WORKSPACE).setState({
        buffers: [editorBuffer("buffer_main", "main.rs") as PaneContent],
        activeBufferId: "buffer_main",
      });
    });
    expect(appliedTitles[appliedTitles.length - 1]).toBe("demo – main.rs");

    // Focus moves to a tool tab: file segment disappears.
    await act(async () => {
      useBufferStore.getStore(WORKSPACE).setState({
        buffers: [editorBuffer("buffer_main", "main.rs"), terminalBuffer("buffer_term")],
        activeBufferId: "buffer_term",
      });
    });
    expect(appliedTitles[appliedTitles.length - 1]).toBe("demo");

    // Unrelated buffer edits (new array/object identities, same active tab)
    // must not re-send the unchanged title.
    const callsAfterToolTab = appliedTitles.length;
    await act(async () => {
      const edited = editorBuffer("buffer_main", "main.rs");
      edited.content = "fn main() {}";
      useBufferStore.getStore(WORKSPACE).setState({
        buffers: [edited, terminalBuffer("buffer_term")],
        activeBufferId: "buffer_term",
      });
    });
    expect(appliedTitles.length).toBe(callsAfterToolTab);

    await act(async () => {
      root?.unmount();
    });
  } finally {
    try {
      await act(async () => root?.unmount());
    } finally {
      container.remove();
      if (previousActEnvironment === undefined) {
        delete actEnvironment.IS_REACT_ACT_ENVIRONMENT;
      } else {
        actEnvironment.IS_REACT_ACT_ENVIRONMENT = previousActEnvironment;
      }
      restoreDom();
    }
  }
});
