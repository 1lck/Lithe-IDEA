import { afterAll, afterEach, beforeAll, describe, expect, mock, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";

let nativeMenuBar = false;
let keybindingPreset: "none" | "jetbrains" = "none";
let vimMode = false;

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
        vimMode,
        nativeMenuBar,
        keybindingPreset,
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

afterEach(async () => {
  nativeMenuBar = false;
  keybindingPreset = "none";
  vimMode = false;
  keymapRegistry.clear();
  await act(async () => {
    useKeymapStore.getState().actions.resetToDefaults();
    useKeymapStore.getState().actions.setContexts({
      editorFocus: false,
      terminalFocus: false,
      isRecordingKeybinding: false,
    });
  });
  document.body
    .querySelectorAll("[data-keymap-fixture], .monaco-editor")
    .forEach((element) => element.remove());
});

afterAll(async () => {
  await act(async () => {
    root.unmount();
  });
  restoreDom();
});

describe("keymap input routing", () => {
  test("routes Ctrl+Alt+L and the existing Shift+Alt+F alias to document formatting", async () => {
    const formatDocument = mock(() => undefined);
    keymapRegistry.registerCommand({
      id: "editor.formatDocument",
      title: "Format Document",
      execute: formatDocument,
    });
    registerDefaultKeymaps();

    const monaco = document.createElement("div");
    monaco.className = "monaco-editor";
    const editorInput = document.createElement("textarea");
    editorInput.className = "inputarea";
    monaco.append(editorInput);
    document.body.append(monaco);
    editorInput.focus();

    const event = new KeyboardEvent("keydown", {
      key: "l",
      code: "KeyL",
      ctrlKey: true,
      altKey: true,
      bubbles: true,
      cancelable: true,
    });
    await act(async () => {
      editorInput.dispatchEvent(event);
    });

    expect(event.defaultPrevented).toBe(true);
    expect(formatDocument).toHaveBeenCalledTimes(1);

    const compatibilityEvent = new KeyboardEvent("keydown", {
      key: "f",
      code: "KeyF",
      shiftKey: true,
      altKey: true,
      bubbles: true,
      cancelable: true,
    });
    await act(async () => {
      editorInput.dispatchEvent(compatibilityEvent);
    });

    expect(compatibilityEvent.defaultPrevented).toBe(true);
    expect(formatDocument).toHaveBeenCalledTimes(2);
  });

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

function inputFixture(kind: "editor" | "terminal" | "input") {
  const wrapper = document.createElement("div");
  wrapper.dataset.keymapFixture = "true";
  wrapper.className =
    kind === "editor" ? "monaco-editor" : kind === "terminal" ? "terminal-container" : "";
  const input = document.createElement("textarea");
  input.className =
    kind === "editor" ? "inputarea" : kind === "terminal" ? "xterm-helper-textarea" : "";
  wrapper.append(input);
  document.body.append(wrapper);
  input.focus();
  return input;
}
async function press(
  input: HTMLElement,
  key: string,
  modifiers: KeyboardEventInit = { ctrlKey: true },
) {
  const event = new KeyboardEvent("keydown", {
    key,
    code: key.length === 1 ? `Key${key.toUpperCase()}` : key,
    bubbles: true,
    cancelable: true,
    ...modifiers,
  });
  await act(async () => {
    input.dispatchEvent(event);
  });
  return event;
}
function action(id: string) {
  const execute = mock(() => undefined);
  keymapRegistry.registerCommand({ id, title: id, execute });
  return execute;
}

test("switching to JetBrains takes effect immediately: Ctrl+D duplicate, Ctrl+Y delete, Ctrl+W expand without closing", async () => {
  const duplicate = action("editor.duplicateLine");
  const occurrence = action("editor.selectNextOccurrence");
  const remove = action("editor.deleteLine");
  const redo = action("editor.redo");
  const expand = action("editor.expandSelection");
  const shrink = action("editor.shrinkSelection");
  const close = action("file.close");
  const closeWindow = action("workbench.closeWindow");
  registerDefaultKeymaps();
  const input = inputFixture("editor");
  await press(input, "d");
  expect(occurrence).toHaveBeenCalledTimes(1);
  keybindingPreset = "jetbrains";
  expect((await press(input, "d")).defaultPrevented).toBe(true);
  await press(input, "y");
  await press(input, "w");
  await press(input, "w", { ctrlKey: true, shiftKey: true });
  expect(duplicate).toHaveBeenCalledTimes(1);
  expect(remove).toHaveBeenCalledTimes(1);
  expect(expand).toHaveBeenCalledTimes(1);
  expect(shrink).toHaveBeenCalledTimes(1);
  expect(close).not.toHaveBeenCalled();
  expect(closeWindow).not.toHaveBeenCalled();
  expect(redo).not.toHaveBeenCalled();
  await press(input, "F4");
  expect(close).toHaveBeenCalledTimes(1);
  await press(input, "z", { ctrlKey: true, shiftKey: true });
  expect(redo).toHaveBeenCalledTimes(1);
});

test("JetBrains navigation and aliases work with the Windows native-menu preference enabled", async () => {
  keybindingPreset = "jetbrains";
  nativeMenuBar = true;
  const definition = action("editor.goToDefinition");
  const refs = action("editor.goToReferences");
  const files = action("file.quickOpen");
  const project = action("workbench.showFileExplorer");
  registerDefaultKeymaps();
  const input = inputFixture("editor");
  await press(input, "b");
  await press(input, "F7", { altKey: true });
  expect(definition).toHaveBeenCalledTimes(1);
  expect(refs).toHaveBeenCalledTimes(1);
  await press(input, "e");
  await press(input, "n", { ctrlKey: true, shiftKey: true });
  expect(files).toHaveBeenCalledTimes(2);
  input.blur();
  await press(document.body, "1", { altKey: true });
  expect(project).toHaveBeenCalledTimes(1);
});

test("JetBrains leaves editor commands out of terminals and native inputs while preserving terminal bindings", async () => {
  keybindingPreset = "jetbrains";
  const duplicate = action("editor.duplicateLine");
  const remove = action("editor.deleteLine");
  const split = action("terminal.split");
  registerDefaultKeymaps();
  await act(async () => useKeymapStore.getState().actions.setContexts({ editorFocus: true }));
  for (const kind of ["terminal", "input"] as const) {
    const input = inputFixture(kind);
    expect((await press(input, "d")).defaultPrevented).toBe(kind === "terminal");
    expect((await press(input, "y")).defaultPrevented).toBe(false);
  }
  expect(split).toHaveBeenCalledTimes(1);
  expect(duplicate).not.toHaveBeenCalled();
  expect(remove).not.toHaveBeenCalled();
});

test("user shortcut overrides take priority over the JetBrains preset", async () => {
  keybindingPreset = "jetbrains";
  const duplicate = action("editor.duplicateLine");
  const occurrence = action("editor.selectNextOccurrence");
  registerDefaultKeymaps();
  await act(async () =>
    useKeymapStore.getState().actions.addKeybinding({
      key: "ctrl+d",
      command: "editor.selectNextOccurrence",
      source: "user",
      when: "editorFocus",
    }),
  );
  await press(inputFixture("editor"), "d");
  expect(occurrence).toHaveBeenCalledTimes(1);
  expect(duplicate).not.toHaveBeenCalled();
});

test("JetBrains Run/Debug/Stop and stepping shortcuts dispatch their shared actions", async () => {
  keybindingPreset = "jetbrains";
  const cases: [string, KeyboardEventInit, string][] = [
    ["F10", { shiftKey: true }, "run.runSelectedConfiguration"],
    ["F9", { shiftKey: true }, "debug.start"],
    ["F2", { ctrlKey: true }, "run.stopSelectedConfiguration"],
    ["F8", { ctrlKey: true }, "debug.toggleBreakpoint"],
    ["F9", {}, "debug.continue"],
    ["F8", {}, "debug.stepOver"],
    ["F7", {}, "debug.stepInto"],
    ["F8", { shiftKey: true }, "debug.stepOut"],
  ];
  const commands = cases.map(([, , id]) => action(id));
  registerDefaultKeymaps();
  for (const [key, modifiers] of cases)
    expect((await press(document.body, key, modifiers)).defaultPrevented).toBe(true);
  for (const command of commands) expect(command).toHaveBeenCalledTimes(1);
});
