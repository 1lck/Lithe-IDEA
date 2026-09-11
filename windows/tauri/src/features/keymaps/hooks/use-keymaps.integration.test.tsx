import { afterAll, afterEach, beforeAll, describe, expect, mock, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";

let nativeMenuBar = false;

mock.module("@tauri-apps/plugin-os", () => ({
  arch: () => "x86_64",
  platform: () => "windows",
}));

const restoreDom = installHappyDom();
(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT =
  true;

mock.module("@/features/settings/stores/settings.store", () => ({
  useSettingsStore: {
    getState: () => ({
      settings: {
        vimMode: false,
        nativeMenuBar,
        keybindingPreset: "none",
      },
    }),
  },
}));
mock.module("@/features/window/stores/ui-state.store", () => ({
  useUIState: {
    getState: () => ({
      hasOpenModal: () => false,
      closeTopModal: () => undefined,
    }),
  },
}));

const { useKeymaps } = await import("./use-keymaps");
const { useKeymapStore } = await import("../stores/keymaps.store");
const { registerDefaultKeymaps } = await import("../defaults/register-defaults");
const { keymapRegistry } = await import("../utils/registry");

let root: Root;
let container: HTMLDivElement;

function Probe() {
  useKeymaps();
  return null;
}

beforeAll(async () => {
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  await act(async () => {
    root.render(<Probe />);
  });
});

afterEach(() => {
  nativeMenuBar = false;
  keymapRegistry.clear();
  useKeymapStore.getState().actions.resetToDefaults();
  useKeymapStore.getState().actions.setContexts({
    editorFocus: false,
    terminalFocus: false,
    isRecordingKeybinding: false,
  });
  document.body.querySelector(".monaco-editor")?.remove();
});

afterAll(async () => {
  await act(async () => {
    root.unmount();
  });
  restoreDom();
});

describe("keymap input routing", () => {
  test("routes Ctrl+Alt+Left and Ctrl+Alt+Right to history navigation in the Monaco editor", async () => {
    const goBack = mock(() => undefined);
    const goForward = mock(() => undefined);
    const previousTab = mock(() => undefined);
    const nextTab = mock(() => undefined);
    keymapRegistry.registerCommand({
      id: "navigation.goBack",
      title: "Go Back",
      execute: goBack,
    });
    keymapRegistry.registerCommand({
      id: "navigation.goForward",
      title: "Go Forward",
      execute: goForward,
    });
    keymapRegistry.registerCommand({
      id: "workbench.previousTab",
      title: "Previous Tab",
      execute: previousTab,
    });
    keymapRegistry.registerCommand({
      id: "workbench.nextTab",
      title: "Next Tab",
      execute: nextTab,
    });
    registerDefaultKeymaps();

    const monaco = document.createElement("div");
    monaco.className = "monaco-editor";
    const editorInput = document.createElement("textarea");
    editorInput.className = "inputarea";
    monaco.append(editorInput);
    document.body.append(monaco);
    editorInput.focus();

    const goBackEvent = new KeyboardEvent("keydown", {
      key: "ArrowLeft",
      code: "ArrowLeft",
      ctrlKey: true,
      altKey: true,
      bubbles: true,
      cancelable: true,
    });
    await act(async () => {
      editorInput.dispatchEvent(goBackEvent);
    });

    expect(goBackEvent.defaultPrevented).toBe(true);
    expect(goBack).toHaveBeenCalledTimes(1);
    expect(previousTab).not.toHaveBeenCalled();

    const goForwardEvent = new KeyboardEvent("keydown", {
      key: "ArrowRight",
      code: "ArrowRight",
      ctrlKey: true,
      altKey: true,
      bubbles: true,
      cancelable: true,
    });
    await act(async () => {
      editorInput.dispatchEvent(goForwardEvent);
    });

    expect(goForwardEvent.defaultPrevented).toBe(true);
    expect(goForward).toHaveBeenCalledTimes(1);
    expect(nextTab).not.toHaveBeenCalled();
  });

  test("keeps history navigation in the frontend when the Windows native menu setting is enabled", async () => {
    nativeMenuBar = true;
    const goBack = mock(() => undefined);
    keymapRegistry.registerCommand({
      id: "navigation.goBack",
      title: "Go Back",
      execute: goBack,
    });
    registerDefaultKeymaps();

    const event = new KeyboardEvent("keydown", {
      key: "ArrowLeft",
      code: "ArrowLeft",
      ctrlKey: true,
      altKey: true,
      bubbles: true,
      cancelable: true,
    });
    await act(async () => {
      document.body.dispatchEvent(event);
    });

    expect(event.defaultPrevented).toBe(true);
    expect(goBack).toHaveBeenCalledTimes(1);
  });

  test("leaves paste native in Monaco find input and routes it in the editor input area", async () => {
    const pasteIntoEditor = mock(() => undefined);
    keymapRegistry.registerCommand({
      id: "editor.paste",
      title: "Paste",
      execute: pasteIntoEditor,
    });
    keymapRegistry.registerKeybinding({
      key: "ctrl+v",
      command: "editor.paste",
      source: "default",
      when: "editorFocus",
    });
    await act(async () => {
      useKeymapStore.getState().actions.setContexts({ editorFocus: false });
    });

    const monaco = document.createElement("div");
    monaco.className = "monaco-editor";
    const findInput = document.createElement("input");
    monaco.append(findInput);
    document.body.append(monaco);
    findInput.focus();

    const findPaste = new KeyboardEvent("keydown", {
      key: "v",
      ctrlKey: true,
      bubbles: true,
      cancelable: true,
    });
    await act(async () => {
      findInput.dispatchEvent(findPaste);
    });

    expect(findPaste.defaultPrevented).toBe(false);
    expect(pasteIntoEditor).not.toHaveBeenCalled();

    const editorInput = document.createElement("textarea");
    editorInput.className = "inputarea";
    monaco.append(editorInput);
    editorInput.focus();

    const editorPaste = new KeyboardEvent("keydown", {
      key: "v",
      ctrlKey: true,
      bubbles: true,
      cancelable: true,
    });
    await act(async () => {
      editorInput.dispatchEvent(editorPaste);
    });

    expect(editorPaste.defaultPrevented).toBe(true);
    expect(pasteIntoEditor).toHaveBeenCalledTimes(1);
  });
});
