import { afterEach, expect, mock, test } from "bun:test";
import { enableMapSet } from "immer";
import { createRequire } from "node:module";
import hello from "../../../../../shared/contracts/plugins/v1/fixtures/hello-lithe.plugin.json";
import { useUIExtensionStore } from "@/extensions/ui/stores/ui-extension-store";
enableMapSet();
// Zustand's Bun CJS adapter loads the CommonJS Immer export. Enable its
// MapSet plugin as well as the ESM export used by the product bundler.
createRequire(import.meta.url)("immer").enableMapSet();
const open = mock(async () => undefined);
let manifestGate: Promise<void> | null = null;
mock.module("./declarative-plugin-launch", () => ({
  listDeclarativePlugins: async () => [
    { pluginId: hello.id, displayName: hello.displayName, enabled: true, status: "accepted" },
  ],
  listDeclarativeWebWindows: async () => [
    { pluginId: hello.id, windowId: hello.ui.toolWindows[0].id, title: hello.displayName },
  ],
  getDeclarativePluginManifest: async () => {
    await manifestGate;
    return hello;
  },
  openDeclarativeWebWindow: open,
}));
const { refreshDeclarativeUI, removeDeclarativeUI, useDeclarativePluginUI } =
  await import("./declarative-plugin-ui");
afterEach(() => {
  removeDeclarativeUI(hello.id);
  open.mockClear();
  manifestGate = null;
});

test("hello ui1 contributes a text window and all three command placements and revokes them", async () => {
  await refreshDeclarativeUI();
  const state = useUIExtensionStore.getState();
  const command = [...state.commands.values()].find(
    (command) => command.extensionId === `declarative:${hello.id}`,
  )!;
  expect(command.placements).toEqual(["commandPalette", "toolbar", "menu"]);
  expect(useDeclarativePluginUI.getState().windows).toHaveLength(1);
  expect([...state.toolbarActions.values()].some((action) => action.id === command.id)).toBe(true);
  await command.execute();
  expect(open).toHaveBeenCalledWith(hello.id, hello.ui.toolWindows[0].id);
  removeDeclarativeUI(hello.id);
  expect(useDeclarativePluginUI.getState().windows).toHaveLength(0);
  expect(useUIExtensionStore.getState().commands.has(command.id)).toBe(false);
  expect(useUIExtensionStore.getState().toolbarActions.has(command.id)).toBe(false);
});

test("removing another plugin does not cancel an in-flight refresh", async () => {
  let release!: () => void;
  manifestGate = new Promise<void>((resolve) => {
    release = resolve;
  });
  const refreshing = refreshDeclarativeUI();
  removeDeclarativeUI("test.unrelated");
  try {
    release();
    await refreshing;
    expect(
      useDeclarativePluginUI.getState().windows.some((window) => window.pluginId === hello.id),
    ).toBe(true);
    expect(
      [...useUIExtensionStore.getState().commands.values()].some(
        (command) => command.extensionId === `declarative:${hello.id}`,
      ),
    ).toBe(true);
  } finally {
    release();
  }
}, 5000);

test("revoking the same plugin rejects its in-flight UI contribution", async () => {
  let release!: () => void;
  manifestGate = new Promise<void>((resolve) => {
    release = resolve;
  });
  const refreshing = refreshDeclarativeUI();
  removeDeclarativeUI(hello.id);
  try {
    release();
    await refreshing;
    expect(
      useDeclarativePluginUI.getState().windows.some((window) => window.pluginId === hello.id),
    ).toBe(false);
  } finally {
    release();
  }
}, 5000);
