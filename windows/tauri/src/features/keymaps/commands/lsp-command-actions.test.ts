import { beforeEach, expect, mock, test } from "bun:test";

let rootFolderPath: string | undefined = "C:/fixture/project";
const stop = mock(async (_workspacePath: string) => undefined);
const resolveJavaLspLaunch = mock(async () => ({
  workspaceFingerprint: "build=|modules=|jdtls=1.38.0",
}));
const invoke = mock(async () => undefined);
const info = mock(() => undefined);
const success = mock(() => undefined);
const error = mock(() => undefined);

mock.module("@/features/editor/lsp/lsp-client", () => ({
  LspClient: {
    getInstance: () => ({
      getActiveServerEntries: () => [],
      restartAllTrackedServers: async () => undefined,
      stop,
      stopAll: async () => undefined,
    }),
  },
}));
mock.module("@/features/editor/lsp/java-lsp-host-api", () => ({ resolveJavaLspLaunch }));
mock.module("@/features/settings/stores/settings.store", () => ({
  useSettingsStore: {
    getState: () => ({
      settings: { displayLanguage: "en" },
    }),
  },
}));
mock.module("@/features/window/stores/project.store", () => ({
  useProjectStore: { getState: () => ({ rootFolderPath }) },
}));
mock.module("@/i18n/locale", () => ({
  createTranslator: () => (key: string) => key,
}));
mock.module("@/platform/tauri-core", () => ({ invoke }));
mock.module("sonner", () => ({ toast: { error, info, success } }));

const { rebuildJavaIndex } = await import("./lsp-command-actions");

beforeEach(() => {
  rootFolderPath = "C:/fixture/project";
  stop.mockClear();
  resolveJavaLspLaunch.mockClear();
  invoke.mockClear();
  info.mockClear();
  success.mockClear();
  error.mockClear();
});

test("rebuild Java index stops and clears only the current workspace state", async () => {
  await rebuildJavaIndex();

  expect(resolveJavaLspLaunch).toHaveBeenCalledWith("C:/fixture/project");
  expect(stop).toHaveBeenCalledWith("C:/fixture/project");
  expect(invoke).toHaveBeenCalledWith("lsp_rebuild_java_index", {
    workspacePath: "C:/fixture/project",
    workspaceFingerprint: "build=|modules=|jdtls=1.38.0",
  });
  expect(success).toHaveBeenCalledWith("lsp.javaIndexCleared");
});

test("rebuild Java index requires an open workspace", async () => {
  rootFolderPath = undefined;

  await rebuildJavaIndex();

  expect(info).toHaveBeenCalledWith("lsp.noProject");
  expect(resolveJavaLspLaunch).not.toHaveBeenCalled();
  expect(stop).not.toHaveBeenCalled();
  expect(invoke).not.toHaveBeenCalled();
});
