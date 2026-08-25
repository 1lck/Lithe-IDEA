import { beforeEach, expect, mock, test } from "bun:test";

const tauriInvoke = mock(async () => undefined);

mock.module("@tauri-apps/api/core", () => ({
  Channel: class {},
  convertFileSrc: (path: string) => path,
  invoke: tauriInvoke,
}));

const { invoke, isNativeCommand } = await import("./tauri-core");

beforeEach(() => {
  tauriInvoke.mockClear();
});

test("Java index maintenance routes directly to the Tauri host", async () => {
  const args = {
    workspacePath: "C:/fixture/project",
    workspaceFingerprint: "build=|modules=|jdtls=1.38.0",
  };

  expect(isNativeCommand("lsp_rebuild_java_index")).toBe(true);
  await invoke("lsp_rebuild_java_index", args);

  expect(tauriInvoke).toHaveBeenCalledWith("lsp_rebuild_java_index", args, undefined);
});
