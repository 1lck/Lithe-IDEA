import { afterEach, expect, mock, test } from "bun:test";
const handlers = new Map<string, (event: { payload: any }) => Promise<void>>();
const targets = new Map<string, unknown>();
const invoke = mock(async (_command: string, _args: unknown) => undefined);
const select = mock(async (..._args: unknown[]) => undefined);
let root = "C:/a";
let workspaceId = "workspace-a";
let editorOpened = true;
let windowLabel = "workspace-owner";
const stoppedRuns: unknown[][] = [];
const stoppedLsp: unknown[][] = [];
const removedUI: string[] = [];
let refreshes = 0;
let resolveFile = async (_path: string, _root: string) => "C:/a/file.txt";
mock.module("@tauri-apps/api/event", () => ({
  listen: async (event: string, handler: (event: any) => Promise<void>, options: unknown) => {
    handlers.set(event, handler);
    targets.set(event, options);
    return () => {
      handlers.delete(event);
      targets.delete(event);
    };
  },
}));
mock.module("@tauri-apps/api/window", () => ({
  getCurrentWindow: () => ({ label: windowLabel }),
}));
mock.module("@/platform/tauri-core", () => ({ invoke }));
mock.module("@/features/file-system/stores/file-system.store", () => ({
  useFileSystemStore: { getState: () => ({ rootFolderPath: root, handleFileSelect: select }) },
}));
mock.module("@/features/workspace/runtime/workspace-runtime-registry", () => ({
  workspaceRuntimeRegistry: { getActiveWorkspaceId: () => workspaceId },
}));
mock.module("@/features/editor/stores/buffer.store", () => ({
  useBufferStore: {
    getStore: () => ({
      getState: () => ({
        buffers: editorOpened ? [{ id: "file", path: "C:/a/file.txt" }] : [],
        activeBufferId: editorOpened ? "file" : null,
      }),
    }),
  },
}));
mock.module("./plugin-web-path", () => ({
  resolvePluginWebFilePath: (path: string, root: string) => resolveFile(path, root),
}));
mock.module("./plugin-web-appearance", () => ({
  initializePluginWebAppearanceSync: () => () => {},
}));
// Build routing has its own real-store/identity suite. This listener suite
// keeps its existing minimal workspace double and verifies shared cleanup.
const releaseBuildListener = mock(() => {});
mock.module("./plugin-web-build", () => ({
  initializePluginWebBuildListener: async () => releaseBuildListener,
}));
const releaseFunctionListener = mock(() => {});
mock.module("./plugin-web-function", () => ({
  initializePluginWebFunctionListener: async () => releaseFunctionListener,
}));
mock.module("./declarative-plugin-ui", () => ({
  removeDeclarativeUI: (id: string) => {
    removedUI.push(id);
  },
  refreshDeclarativeUI: async () => {
    refreshes++;
  },
}));
let stopRuns = async () => {};
let stopLsp = async () => {};
mock.module("./declarative-plugin-process-owner", () => ({
  declarativePluginProcessOwner: {
    stop: (...args: unknown[]) => {
      stoppedRuns.push(args);
      return stopRuns();
    },
  },
}));
mock.module("@/platform/lsp-core-adapter", () => ({
  invokeLsp: (...args: unknown[]) => {
    stoppedLsp.push(args);
    return stopLsp();
  },
}));
const { initializePluginWebListeners } = await import("./plugin-web-open-file");
const { assertPluginActive, setPluginActive } = await import("./declarative-plugin-lifecycle");
let dispose: (() => void) | undefined;
afterEach(() => {
  dispose?.();
  dispose = undefined;
  releaseBuildListener.mockClear();
  releaseFunctionListener.mockClear();
  invoke.mockClear();
  select.mockClear();
  root = "C:/a";
  workspaceId = "workspace-a";
  editorOpened = true;
  windowLabel = "workspace-owner";
  stoppedRuns.length = 0;
  stoppedLsp.length = 0;
  removedUI.length = 0;
  refreshes = 0;
  setPluginActive("test.plugin", true);
});
const request = {
  pluginId: "test.plugin",
  operationId: "request-1",
  workspaceId: "workspace-a",
  workspacePath: "C:/a",
  path: "file.txt",
  line: 3,
  column: 2,
};

test("file requests and lifecycle barriers listen only to their owning product window", async () => {
  dispose = await initializePluginWebListeners();
  const scoped = { target: { kind: "Window", label: "workspace-owner" } };
  expect(targets.get("plugin-web-open-file")).toEqual(scoped);
  expect(targets.get("declarative-plugin-lifecycle")).toEqual(scoped);
});

test("mutation acknowledgement waits for both process owners and carries failures", async () => {
  dispose = await initializePluginWebListeners();
  let release: (() => void) | undefined;
  stopRuns = () =>
    new Promise<void>((resolve) => {
      release = resolve;
    });
  stopLsp = async () => {
    throw new Error("process still running");
  };
  const draining = handlers.get("declarative-plugin-lifecycle")!({
    payload: { pluginId: "test.plugin", active: false, operationId: "mutation-1" },
  });
  try {
    expect(() => assertPluginActive("test.plugin")).toThrow("inactive");
    expect(invoke).not.toHaveBeenCalled();
    release?.();
    await draining;
    expect(invoke).toHaveBeenCalledWith("declarative_plugins_lifecycle_ack", {
      operationId: "mutation-1",
      error: "Error: process still running",
    });
  } finally {
    release?.();
    await draining;
    stopRuns = async () => {};
    stopLsp = async () => {};
  }
}, 5000);

test("global reload drains each product window without filtering the workspace or other plugins", async () => {
  windowLabel = "main";
  const releaseFirst = await initializePluginWebListeners();
  const first = handlers.get("declarative-plugin-lifecycle")!;
  expect(targets.get("declarative-plugin-lifecycle")).toEqual({
    target: { kind: "Window", label: "main" },
  });
  windowLabel = "workspace-second";
  const releaseSecond = await initializePluginWebListeners();
  const second = handlers.get("declarative-plugin-lifecycle")!;
  expect(targets.get("declarative-plugin-lifecycle")).toEqual({
    target: { kind: "Window", label: "workspace-second" },
  });
  const gates: Array<() => void> = [];
  stopRuns = () =>
    new Promise<void>((resolve) => {
      gates.push(resolve);
    });
  const payload = { pluginId: "test.plugin", active: false, operationId: "global-reload" };
  const drainingFirst = first({ payload });
  root = "C:/different-workspace";
  workspaceId = "workspace-b";
  const drainingSecond = second({ payload });
  try {
    expect(stoppedRuns).toEqual([
      [undefined, "test.plugin"],
      [undefined, "test.plugin"],
    ]);
    expect(stoppedLsp).toEqual([
      ["lsp_stop_for_provider", { providerId: "test.plugin" }],
      ["lsp_stop_for_provider", { providerId: "test.plugin" }],
    ]);
    expect(removedUI).toEqual(["test.plugin", "test.plugin"]);
    expect(() => assertPluginActive("unrelated.plugin")).not.toThrow();
    expect(invoke).not.toHaveBeenCalled();
    gates[0]!();
    await drainingFirst;
    expect(invoke).toHaveBeenCalledTimes(1);
    gates[1]!();
    await drainingSecond;
    expect(invoke).toHaveBeenCalledTimes(2);
    expect(refreshes).toBe(0);
    await first({ payload: { pluginId: "test.plugin", active: true } });
    expect(refreshes).toBe(1);
    expect(stoppedRuns).toHaveLength(2);
  } finally {
    for (const release of gates) release();
    await Promise.all([drainingFirst, drainingSecond]);
    stopRuns = async () => {};
    releaseFirst();
    releaseSecond();
  }
}, 1000);

test("openFile rejects another workspace and a workspace switch during canonicalization", async () => {
  dispose = await initializePluginWebListeners();
  root = "C:/b";
  workspaceId = "workspace-b";
  await handlers.get("plugin-web-open-file")!({ payload: request });
  expect(select).not.toHaveBeenCalled();
  expect(invoke.mock.calls[0]?.[1]).toEqual(
    expect.objectContaining({ error: expect.stringContaining("no longer active") }),
  );
  root = "C:/a";
  workspaceId = "workspace-a";
  resolveFile = async () => {
    workspaceId = "workspace-b";
    return "C:/a/file.txt";
  };
  await handlers.get("plugin-web-open-file")!({ payload: request });
  expect(select).not.toHaveBeenCalled();
  expect(invoke.mock.calls[1]?.[1]).toEqual(
    expect.objectContaining({ error: expect.stringContaining("changed during") }),
  );
}, 5000);

test("openFile acknowledges success after the owning editor opens the canonical file", async () => {
  dispose = await initializePluginWebListeners();
  resolveFile = async () => "C:/a/file.txt";
  await handlers.get("plugin-web-open-file")!({ payload: request });
  expect(select).toHaveBeenCalledWith("C:/a/file.txt", false, 3, 2, undefined, false);
  expect(invoke).toHaveBeenCalledWith("declarative_plugins_web_open_file_ack", {
    operationId: "request-1",
    error: null,
  });
}, 5000);

test("openFile reports a read failure even when the shared handler resolves", async () => {
  dispose = await initializePluginWebListeners();
  resolveFile = async () => "C:/a/file.txt";
  editorOpened = false;
  await handlers.get("plugin-web-open-file")!({ payload: request });
  expect(invoke).toHaveBeenCalledWith("declarative_plugins_web_open_file_ack", {
    operationId: "request-1",
    error: "Error: the editor did not open the requested file",
  });
}, 5000);
