import { afterAll, expect, spyOn, test } from "bun:test";
import { act, forwardRef, type ReactNode } from "react";
import type { Root } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";

import * as animation from "motion/react";
import * as nativeDialog from "@tauri-apps/plugin-dialog";
import * as nativeFs from "@tauri-apps/plugin-fs";
import * as toast from "@/features/layout/contexts/toast-context";
import { useKeymapStore } from "@/features/keymaps/stores/keymaps.store";
import { keymapRegistry } from "@/features/keymaps/utils/registry";
import { getDefaultSettingsSnapshot } from "@/features/settings/config/default-settings";
import * as persistence from "@/features/settings/lib/settings-persistence";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { WorkspaceStoreScopeContext } from "@/features/workspace/stores/create-workspace-scoped-store";
import { LocaleProvider } from "@/i18n/locale-provider";
import * as dialog from "@/ui/dialog";
import SettingsDialog from "./settings-dialog";

// React DOM must detect the DOM before initializing its input event handling.
const restoreDom = installHappyDom();
afterAll(restoreDom);
const { createRoot } = await import("react-dom/client");

test("keyboard settings route supports searching, recording and resetting a command binding", async () => {
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  const previousSettings = useSettingsStore.getState().settings;
  const previousKeymaps = useKeymapStore.getState();
  const previousCommands = keymapRegistry.getAllCommands();
  const previousBindings = keymapRegistry.getAllKeybindings();
  const workspaceId = "keyboard-settings-routing-test";
  const save = spyOn(persistence, "debouncedSaveSettingsToStore").mockImplementation(() => {});
  const frame = spyOn(dialog, "default").mockImplementation(({ children }) => (
    <div>{children}</div>
  ));
  // Test settings behavior without waiting for animation frames or native dialog focus.
  const presence = spyOn(animation, "AnimatePresence").mockImplementation(({ children }) => (
    <>{children}</>
  ));
  const motionDiv = spyOn(animation.motion, "div").mockImplementation(
    forwardRef<HTMLDivElement, animation.HTMLMotionProps<"div">>(({ children, className }, ref) => (
      <div ref={ref} className={className}>
        {children as ReactNode}
      </div>
    )) as typeof animation.motion.div,
  );
  const exportPath = "/test/keybindings.json";
  const exportDialog = spyOn(nativeDialog, "save").mockResolvedValue(exportPath);
  const writeFile = spyOn(nativeFs, "writeTextFile").mockResolvedValue();
  const notifications = spyOn(toast, "useToast").mockReturnValue({
    showToast: () => "test-toast",
    updateToast: () => {},
    dismissToast: () => {},
    hasToast: () => false,
  });
  let importInput: HTMLInputElement | undefined;
  const chooseFile = spyOn(HTMLInputElement.prototype, "click").mockImplementation(
    function (this: HTMLInputElement) {
      importInput = this;
    },
  );
  const container = document.createElement("div");
  let root: Root | undefined;
  const button = (label: string) => {
    const result = Array.from(container.querySelectorAll("button")).find(
      (item) => item.textContent === label || item.getAttribute("aria-label") === label,
    );
    expect(result).toBeDefined();
    return result!;
  };
  try {
    environment.IS_REACT_ACT_ENVIRONMENT = true;
    useSettingsStore.setState({
      settings: { ...getDefaultSettingsSnapshot(), keybindingPreset: "none" },
    });
    useKeymapStore.setState({ keybindings: [] });
    keymapRegistry.clear();
    keymapRegistry.registerCommand({
      id: "editor.goToImplementation",
      title: "Go to Implementation",
      execute: () => {},
    });
    keymapRegistry.registerCommand({
      id: "editor.formatDocument",
      title: "Format Document",
      execute: () => {},
    });
    keymapRegistry.registerKeybinding({
      key: "ctrl+f12",
      command: "editor.goToImplementation",
      source: "default",
      when: "editorFocus",
    });
    useUIState.getStore(workspaceId).setState({ settingsInitialTab: "keyboard" });
    document.body.append(container);
    root = createRoot(container);
    const mountedRoot = root;
    await act(async () => {
      mountedRoot.render(
        <WorkspaceStoreScopeContext.Provider value={workspaceId}>
          <LocaleProvider language="en-US">
            <SettingsDialog isOpen onClose={() => {}} />
          </LocaleProvider>
        </WorkspaceStoreScopeContext.Provider>,
      );
    });
    await act(async () => button("Open Editor").click());
    expect(button("Import")).toBeDefined();
    expect(button("Export")).toBeDefined();
    expect(container.textContent).toContain("editor.formatDocument");
    const search = container.querySelector("input")!;
    expect(search).not.toBeNull();
    const setInputValue = Object.getOwnPropertyDescriptor(
      HTMLInputElement.prototype,
      "value",
    )!.set!;
    const searchFor = async (query: string) => {
      await act(async () => {
        setInputValue.call(search, query);
        search.dispatchEvent(new Event("input", { bubbles: true }));
      });
    };
    await searchFor("f12");
    expect(container.textContent).toContain("editor.goToImplementation");
    expect(container.textContent).not.toContain("editor.formatDocument");
    await searchFor("implementation");
    const edit = container.querySelector<HTMLButtonElement>("tbody tr button")!;
    await act(async () => edit.click());
    expect(useKeymapStore.getState().recordingCommandId).toBe("editor.goToImplementation");
    await act(async () => {
      window.dispatchEvent(
        new KeyboardEvent("keydown", {
          key: "b",
          code: "KeyB",
          ctrlKey: true,
          altKey: true,
          bubbles: true,
        }),
      );
    });
    await act(async () => {
      window.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
    });
    expect(useKeymapStore.getState().keybindings).toEqual([
      {
        key: "alt+ctrl+b",
        command: "editor.goToImplementation",
        source: "user",
        enabled: true,
        when: "editorFocus",
      },
    ]);
    expect(useKeymapStore.getState().recordingCommandId).toBeNull();
    await act(async () => button("Export").click());
    expect(writeFile).toHaveBeenCalledTimes(1);
    const [path, exported] = writeFile.mock.calls[0]!;
    expect(path).toBe(exportPath);
    expect(JSON.parse(exported).keybindings).toEqual(useKeymapStore.getState().keybindings);
    await searchFor("alt+ctrl+b");
    expect(container.textContent).toContain("editor.goToImplementation");
    await act(async () => button("Reset").click());
    expect(useKeymapStore.getState().keybindings).toEqual([]);
    await searchFor("f12");
    expect(container.textContent).toContain("editor.goToImplementation");
    await act(async () => button("Import").click());
    expect(importInput).toBeDefined();
    Object.defineProperty(importInput!, "files", { value: [{ text: async () => exported }] });
    await act(async () => {
      await importInput!.onchange!.call(importInput!, { target: importInput } as unknown as Event);
    });
    expect(useKeymapStore.getState().keybindings).toEqual(JSON.parse(exported).keybindings);
    await searchFor("no-such-command");
    expect(container.querySelectorAll("tbody tr")).toHaveLength(1);
    expect(container.textContent).not.toContain("editor.goToImplementation");
  } finally {
    try {
      await act(async () => root?.unmount());
    } finally {
      container.remove();
      chooseFile.mockRestore();
      notifications.mockRestore();
      writeFile.mockRestore();
      exportDialog.mockRestore();
      motionDiv.mockRestore();
      presence.mockRestore();
      frame.mockRestore();
      save.mockRestore();
      useSettingsStore.setState({ settings: previousSettings });
      useKeymapStore.setState(previousKeymaps);
      keymapRegistry.clear();
      for (const command of previousCommands) keymapRegistry.registerCommand(command);
      for (const binding of previousBindings) keymapRegistry.registerKeybinding(binding);
      workspaceRuntimeRegistry.removeWorkspace(workspaceId);
      if (previousAct === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
      else environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
    }
  }
});
