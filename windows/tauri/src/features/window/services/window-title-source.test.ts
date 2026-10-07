import { expect, test } from "bun:test";
import { createStore } from "zustand/vanilla";
import type { PaneContent } from "@/features/panes/types/pane-content.types";
import { WorkspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { WELCOME_WORKSPACE_ID } from "@/features/workspace/types/workspace-runtime.types";
import type { WindowTitleBufferState, WindowTitleContext, WindowTitlePaneState, WindowTitleProject } from "../utils/window-title-context";
import { createWindowTitleSource, type WindowTitleSidebarState } from "./window-title-source";
import { startWindowTitleSync } from "./window-title-sync";

function harness() {
  const registry = new WorkspaceRuntimeRegistry();
  const keyboardContext = createStore(() => ({ contexts: { terminalFocus: false, hasSelection: false } }));
  const tabs = createStore<{ projectTabs: WindowTitleProject[] }>(() => ({ projectTabs: [] }));
  const focusListeners = new Set<() => void>();
  let sidebarFocus = false;
  const focus = {
    isSidebarFocused: () => sidebarFocus,
    subscribe: (listener: () => void) => {
      focusListeners.add(listener);
      return () => { focusListeners.delete(listener); };
    },
  };
  registry.registerStore<WindowTitleSidebarState>("window-ui", () => createStore(() => ({
    isSidebarVisible: true, isGitViewActive: false, isGitHubPRsViewActive: false, activeSidebarView: "search",
  })));
  registry.registerStore<WindowTitlePaneState>("pane", () => createStore(() => ({
    root: { id: "main", type: "group", bufferIds: ["file"], activeBufferId: "file" },
    bottomRoot: { id: "bottom", type: "group", bufferIds: [], activeBufferId: null },
    activePaneId: "main",
  })));
  registry.registerStore<WindowTitleBufferState>("editor-buffer", (id) => createStore(() => ({
    buffers: [{ id: "file", type: "image", path: `C:/projects/${id}/${id}.png`, name: `${id}.png`, isActive: true, isPreview: false, isPinned: false } as PaneContent],
  })));
  const addWorkspace = (id: string) => {
    tabs.setState({ projectTabs: [...tabs.getState().projectTabs, { id, name: id, path: `C:/projects/${id}` }] });
    registry.ensureWorkspace({ id, name: id, path: `C:/projects/${id}` }, "ready");
    registry.getStore<WindowTitlePaneState>("pane", id);
    registry.getStore<WindowTitleBufferState>("editor-buffer", id);
  };
  return {
    registry, tabs, keyboardContext, addWorkspace,
    setSidebarFocus: (value: boolean) => { sidebarFocus = value; for (const listener of focusListeners) listener(); },
    source: createWindowTitleSource({ registry, tabs, keyboardContext, focus }),
  };
}

test("search focus clears the file only while the active workspace search sidebar is visible", () => {
  const h = harness(); h.addWorkspace("A"); h.addWorkspace("B");
  h.registry.activateWorkspace({ id: "A", name: "A" }, "ready");
  const uiA = h.registry.getStore<WindowTitleSidebarState>("window-ui", "A");
  const uiB = h.registry.getStore<WindowTitleSidebarState>("window-ui", "B");
  let changes = 0;
  const stop = h.source.subscribe(() => { changes++; });
  try {
    expect(h.source.readContext().fileName).toBe("A.png");
    h.setSidebarFocus(true);
    expect(h.source.readContext().fileName).toBeNull();
    h.setSidebarFocus(false);
    expect(h.source.readContext().fileName).toBe("A.png");
    h.setSidebarFocus(true);
    uiA.setState({ isSidebarVisible: false });
    expect(h.source.readContext().fileName).toBe("A.png");
    uiA.setState({ isSidebarVisible: true, isGitViewActive: true });
    expect(h.source.readContext().fileName).toBe("A.png");
    h.registry.activateWorkspace({ id: "B", name: "B" }, "ready");
    expect(h.source.readContext().fileName).toBeNull();
    const before = changes;
    uiA.setState({ activeSidebarView: "files" });
    expect(changes).toBe(before);
    uiB.setState({ activeSidebarView: "files" });
    expect(changes).toBe(before + 1);
    expect(h.source.readContext().fileName).toBe("B.png");
  } finally { stop(); }
  const before = changes;
  h.setSidebarFocus(false); uiB.setState({ isSidebarVisible: false });
  expect(changes).toBe(before);
});

test("bottom terminal focus clears the editor file and restores it when focus returns", () => {
  const h = harness();
  h.addWorkspace("A");
  h.registry.activateWorkspace({ id: "A", name: "A" }, "ready");
  let changes = 0;
  const stop = h.source.subscribe(() => { changes++; });
  try {
    h.keyboardContext.setState({ contexts: { terminalFocus: true, hasSelection: false } });
    expect(h.source.readContext()).toEqual({
      projects: [{ workspaceId: "A", displayName: "A", path: "C:/projects/A" }],
      activeWorkspaceId: "A", fileName: null,
    });
    expect(changes).toBe(1);
    h.keyboardContext.setState({ contexts: { terminalFocus: true, hasSelection: true } });
    expect(changes).toBe(1);
    h.keyboardContext.setState({ contexts: { terminalFocus: false, hasSelection: true } });
    expect(h.source.readContext().fileName).toBe("A.png");
    expect(changes).toBe(2);
  } finally {
    stop();
  }
  h.keyboardContext.setState({ contexts: { terminalFocus: true, hasSelection: false } });
  expect(changes).toBe(2);
});

test("reads existing state without initializing any workspace stores", () => {
  const h = harness();
  expect(h.source.readContext()).toEqual({ projects: [], activeWorkspaceId: null, fileName: null });
  expect(h.registry.getWorkspace(WELCOME_WORKSPACE_ID)!.stores.size).toBe(0);
});

test("rebinds subscriptions on workspace switches and ignores background editor edits", () => {
  const h = harness();
  h.addWorkspace("A"); h.addWorkspace("B");
  h.registry.activateWorkspace({ id: "A", name: "A" }, "ready");
  let changes = 0;
  const stop = h.source.subscribe(() => { changes++; });
  try {
    expect(h.source.readContext().fileName).toBe("A.png");
    h.registry.activateWorkspace({ id: "B", name: "B" }, "ready");
    expect(h.source.readContext().fileName).toBe("B.png");
    const afterSwitch = changes;
    h.registry.getStore<WindowTitleBufferState>("editor-buffer", "A").setState({ buffers: [] });
    expect(changes).toBe(afterSwitch);
    h.registry.getStore<WindowTitleBufferState>("editor-buffer", "B").setState({ buffers: [] });
    expect(changes).toBe(afterSwitch + 1);
    expect(h.source.readContext().fileName).toBeNull();
  } finally {
    stop();
  }
  const afterStop = changes;
  h.registry.updateWorkspaceStatus("B", "opening");
  h.tabs.setState({ projectTabs: [] });
  expect(changes).toBe(afterStop);
});

test("binds stores created after startup and suppresses stale files while opening", () => {
  const h = harness();
  h.tabs.setState({ projectTabs: [{ id: "A", name: "A", path: "C:/projects/A" }] });
  h.registry.activateWorkspace({ id: "A", name: "A" }, "opening");
  let changes = 0;
  const stop = h.source.subscribe(() => { changes++; });
  try {
    h.registry.getStore<WindowTitlePaneState>("pane", "A");
    const bufferStore = h.registry.getStore<WindowTitleBufferState>("editor-buffer", "A");
    expect(changes).toBe(2);
    expect(h.source.readContext().fileName).toBeNull();
    h.registry.updateWorkspaceStatus("A", "ready");
    expect(h.source.readContext().fileName).toBe("A.png");
    const beforeEdit = changes;
    bufferStore.setState({ buffers: [] });
    expect(changes).toBe(beforeEdit + 1);
  } finally {
    stop();
  }
});

test("includes restored background tabs and observes aliases without changing runtime descriptors", () => {
  const h = harness();
  h.addWorkspace("A"); h.addWorkspace("B");
  h.registry.activateWorkspace({ id: "A", name: "A" }, "ready");
  let changes = 0;
  const stop = h.source.subscribe(() => { changes++; });
  try {
    h.tabs.setState({ projectTabs: h.tabs.getState().projectTabs.map((project) => ({ ...project, displayAlias: "后端" })) });
    expect(changes).toBe(1);
    expect(h.source.readContext().projects.map((project) => project.displayName)).toEqual(["A (后端)", "B (后端)"]);
    expect(h.registry.getWorkspace("A")!.descriptor.name).toBe("A");
  } finally {
    stop();
  }
});

function synchronization(source: ReturnType<typeof createWindowTitleSource>) {
  const requests: WindowTitleContext[] = [];
  const scheduled: Array<() => void> = [];
  const errors: unknown[] = [];
  const stop = startWindowTitleSync({
    ...source,
    subscribeFocus: () => () => {},
    schedule: (callback) => scheduled.push(callback),
    update: async (context) => { requests.push(context); },
    reportError: (error) => errors.push(error),
  });
  return {
    requests, errors, stop,
    flush: () => { while (scheduled.length) scheduled.shift()!(); },
  };
}

test("real buffer body edits do not send additional title requests", async () => {
  const h = harness();
  h.addWorkspace("A");
  h.registry.activateWorkspace({ id: "A", name: "A" }, "ready");
  const store = h.registry.getStore<WindowTitleBufferState>("editor-buffer", "A");
  const buffer: PaneContent = {
    id: "file", type: "editor", name: "App.java", path: "C:/projects/A/App.java",
    isActive: true, isPinned: false, isPreview: false, isVirtual: false, isDirty: false,
    content: "before", savedContent: "before", tokens: [],
  };
  store.setState({ buffers: [buffer] });
  const sync = synchronization(h.source);
  try {
    sync.flush();
    await Promise.resolve();
    store.setState({ buffers: [{ ...buffer, content: "after", isDirty: true }] });
    sync.flush();
    expect(sync.requests).toHaveLength(1);
    expect(sync.requests[0]!.fileName).toBe("App.java");
    expect(sync.errors).toEqual([]);
  } finally {
    sync.stop();
    await Promise.resolve();
  }
});

test("workspace transitions and failed-open rollback never mix project and file names", async () => {
  const h = harness();
  h.addWorkspace("A"); h.addWorkspace("B");
  h.registry.activateWorkspace({ id: "A", name: "A" }, "ready");
  const sync = synchronization(h.source);
  try {
    sync.flush();
    await Promise.resolve();
    h.registry.activateWorkspace({ id: "B", name: "B" }, "ready");
    h.registry.updateWorkspaceStatus("B", "opening");
    sync.flush();
    await Promise.resolve();
    expect(sync.requests[1]!.activeWorkspaceId).toBe("B");
    expect(sync.requests[1]!.fileName).toBeNull();
    h.registry.updateWorkspaceStatus("B", "error");
    h.tabs.setState({ projectTabs: h.tabs.getState().projectTabs.filter((project) => project.id !== "B") });
    h.registry.activateWorkspace({ id: "A", name: "A" }, "ready");
    h.registry.removeWorkspace("B");
    sync.flush();
    expect(sync.requests[2]!.activeWorkspaceId).toBe("A");
    expect(sync.requests[2]!.fileName).toBe("A.png");
    expect(sync.requests[2]!.projects).toHaveLength(1);
    expect(sync.errors).toEqual([]);
  } finally {
    sync.stop();
    await Promise.resolve();
  }
});

test("initialization status forces identity refresh even when title text is unchanged", async () => {
  const h = harness(); h.addWorkspace("A");
  h.registry.activateWorkspace({ id: "A", name: "A" }, "opening");
  h.registry.updateWorkspaceStatus("A", "opening");
  h.registry.getStore<WindowTitleBufferState>("editor-buffer", "A").setState({ buffers: [] });
  const sync = synchronization(h.source);
  try {
    sync.flush(); await Promise.resolve();
    h.registry.updateWorkspaceStatus("A", "ready");
    sync.flush(); await Promise.resolve();
    expect(sync.requests).toHaveLength(2);
    expect(sync.requests[1]).toEqual(sync.requests[0]);
    h.registry.updateWorkspaceStatus("A", "ready");
    sync.flush();
    expect(sync.requests).toHaveLength(2);
  } finally { sync.stop(); await Promise.resolve(); }
});
