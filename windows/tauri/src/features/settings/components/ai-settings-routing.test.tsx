import { expect, spyOn, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import * as autocomplete from "@/features/editor/services/editor-autocomplete-service";
import { getDefaultSettingsSnapshot } from "@/features/settings/config/default-settings";
import * as persistence from "@/features/settings/lib/settings-persistence";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { WorkspaceStoreScopeContext } from "@/features/workspace/stores/create-workspace-scoped-store";
import { LocaleProvider } from "@/i18n/locale-provider";
import * as platform from "@/platform/tauri-core";
import { installHappyDom } from "@/test-utils/happy-dom";
import * as dialog from "@/ui/dialog";
import SettingsDialog from "./settings-dialog";

test("general AI and commit settings remain independently reachable", async () => {
  const restoreDom = installHappyDom();
  const previousSettings = useSettingsStore.getState().settings;
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  const workspaceId = "ai-settings-routing-test";
  const invoke = spyOn(platform, "invoke").mockImplementation(async (command) => {
    if (command === "ai_commit_detect") return { configurations: [], warnings: [] } as never;
    if (command === "get_available_agents") return [] as never;
    return null as never;
  });
  // Exercise real store updates without scheduling persistence or accessing user settings.
  const save = spyOn(persistence, "debouncedSaveSettingsToStore").mockImplementation(() => {});
  const models = spyOn(autocomplete, "fetchAutocompleteModels").mockResolvedValue([]);
  // The native dialog's portal/focus lifecycle is outside this settings routing regression.
  const frame = spyOn(dialog, "default").mockImplementation(({ children }) => (
    <div>{children}</div>
  ));
  const container = document.createElement("div");
  let root: Root | undefined;
  try {
    environment.IS_REACT_ACT_ENVIRONMENT = true;
    const settings = getDefaultSettingsSnapshot();
    settings.aiProviderId = "custom";
    settings.aiCustomModelId = "company-model";
    settings.aiModelId = "company-model";
    settings.aiCustomBaseUrl = "https://old.example.test/v1";
    useSettingsStore.setState({ settings });
    useUIState.getStore(workspaceId).setState({ settingsInitialTab: "ai" });
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
    const baseUrl = Array.from(document.querySelectorAll("input")).find(
      (input) => input.value === "https://old.example.test/v1",
    );
    expect(baseUrl).toBeDefined();
    expect(document.body.textContent).toContain("AI Chat & Editing");
    expect(document.body.textContent).not.toContain("Commit message generation");

    const commitTab = Array.from(document.querySelectorAll("nav button")).find(
      (button) => button.textContent === "AI & Commit",
    );
    expect(commitTab).toBeDefined();
    await act(async () => {
      (commitTab as HTMLButtonElement).click();
    });
    expect(document.body.textContent).toContain("Commit message generation");
    expect(document.querySelector('input[value="https://old.example.test/v1"]')).toBeNull();
    expect(useSettingsStore.getState().settings.aiCustomBaseUrl).toBe(settings.aiCustomBaseUrl);
    expect(useSettingsStore.getState().settings.aiCustomModelId).toBe("company-model");

    const generalTab = Array.from(document.querySelectorAll("nav button")).find(
      (button) => button.textContent === "AI Chat & Editing",
    );
    await act(async () => {
      (generalTab as HTMLButtonElement).click();
    });
    expect(
      Array.from(document.querySelectorAll("input")).some(
        (input) => input.value === settings.aiCustomBaseUrl,
      ),
    ).toBe(true);
  } finally {
    try {
      await act(async () => root?.unmount());
    } finally {
      container.remove();
      invoke.mockRestore();
      save.mockRestore();
      models.mockRestore();
      frame.mockRestore();
      useSettingsStore.setState({ settings: previousSettings });
      workspaceRuntimeRegistry.removeWorkspace(workspaceId);
      if (previousAct === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
      else environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
      restoreDom();
    }
  }
});
