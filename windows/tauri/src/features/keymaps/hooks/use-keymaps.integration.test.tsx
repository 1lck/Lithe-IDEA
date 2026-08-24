import { afterAll, afterEach, beforeAll, describe, expect, mock, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";

const restoreDom = installHappyDom();
(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT =
  true;

mock.module("@/features/settings/stores/settings.store", () => ({
  useSettingsStore: {
    getState: () => ({
      settings: {
        vimMode: false,
        nativeMenuBar: false,
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
  keymapRegistry.clear();
  document.body.querySelector(".monaco-editor")?.remove();
});

afterAll(async () => {
  await act(async () => {
    root.unmount();
  });
  restoreDom();
});

describe("keymap input routing", () => {
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
