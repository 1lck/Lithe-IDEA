import { useFontStore } from "../stores/font.store";
import { expect, spyOn, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import * as effects from "@/features/settings/lib/settings-effects";
import * as persistence from "@/features/settings/lib/settings-persistence";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { WorkspaceStoreScopeContext } from "@/features/workspace/stores/create-workspace-scoped-store";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import * as dialog from "@/ui/dialog";
import SettingsDialog from "./settings-dialog";

test("the actual Editor settings route uses the shared font-size control and persists its step", async () => {
  const restoreDom = installHappyDom();
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  const previousSettings = useSettingsStore.getState().settings;
  const previousFonts = useFontStore.getState();
  const workspaceId = "editor-font-size-routing-test";
  const save = spyOn(persistence, "debouncedSaveSettingsToStore").mockImplementation(() => {});
  const sideEffect = spyOn(effects, "applySettingSideEffect").mockImplementation(() => {});
  // Keep the real category routing and settings store; native modal focus is outside this regression.
  const frame = spyOn(dialog, "default").mockImplementation(({ children, footer }) => (
    <div>
      {children}
      {footer}
    </div>
  ));
  let closed = false;
  const host = document.createElement("div");
  let root: Root | undefined;
  try {
    environment.IS_REACT_ACT_ENVIRONMENT = true;
    useFontStore.setState({
      actions: {
        ...previousFonts.actions,
        loadAvailableFonts: async () => {},
        loadMonospaceFonts: async () => {},
      },
    });
    useSettingsStore.setState({ settings: { ...previousSettings, fontSize: 16 } });
    useUIState.getStore(workspaceId).setState({ settingsInitialTab: "editor" });
    document.body.append(host);
    root = createRoot(host);
    const mountedRoot = root;
    await act(async () =>
      mountedRoot.render(
        <WorkspaceStoreScopeContext.Provider value={workspaceId}>
          <LocaleProvider language="en-US">
            <SettingsDialog
              isOpen
              onClose={() => {
                closed = true;
              }}
            />
          </LocaleProvider>
        </WorkspaceStoreScopeContext.Provider>,
      ),
    );
    expect(host.textContent).toContain("Show usages and Git author");
    const input = host.querySelector<HTMLInputElement>('input[aria-label="Font size"]')!;
    expect(input).not.toBeNull();
    expect(input.type).toBe("text");
    expect(input.value).toBe("16");
    const increase = host.querySelector<HTMLButtonElement>('button[aria-label="Increase value"]')!;
    const decrease = host.querySelector<HTMLButtonElement>('button[aria-label="Decrease value"]')!;
    expect(increase).not.toBeNull();
    expect(decrease).not.toBeNull();
    await act(async () => increase.click());
    expect(input.value).toBe("17");
    expect(useSettingsStore.getState().settings.fontSize).toBe(17);
    expect(save).toHaveBeenLastCalledWith({ fontSize: 17 });
    expect(save).toHaveBeenCalledTimes(1);
    expect(useSettingsStore.getState().settings.showMinimap).toBe(previousSettings.showMinimap);
    const close = Array.from(host.querySelectorAll<HTMLButtonElement>("button")).find(
      (button) => button.textContent === "Close",
    )!;
    await act(async () => close.click());
    expect(closed).toBe(true);
    // Closing preserves the normal settings that were already persisted.
    expect(useSettingsStore.getState().settings.fontSize).toBe(17);
    expect(save).toHaveBeenCalledTimes(1);
  } finally {
    try {
      await act(async () => root?.unmount());
    } finally {
      host.remove();
      frame.mockRestore();
      save.mockRestore();
      sideEffect.mockRestore();
      useSettingsStore.setState({ settings: previousSettings });
      useFontStore.setState(previousFonts, true);
      workspaceRuntimeRegistry.removeWorkspace(workspaceId);
      if (previousAct === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
      else environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
      restoreDom();
    }
  }
});
