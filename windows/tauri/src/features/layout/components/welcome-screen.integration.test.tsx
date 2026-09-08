import { expect, mock, spyOn, test } from "bun:test";
import * as tauriApp from "@tauri-apps/api/app";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { useRecentFoldersStore } from "@/features/file-system/stores/recent-folders.store";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { getProjectPickerInitialState } from "@/features/window/utils/project-picker-mode";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { WorkspaceStoreScopeContext } from "@/features/workspace/stores/create-workspace-scoped-store";
import { createTranslator } from "@/i18n/locale";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import { WelcomeScreen } from "./welcome-screen";

test("welcome Clone opens repository details with no open or recent project", async () => {
  const restoreDom = installHappyDom();
  const actEnvironment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousActEnvironment = actEnvironment.IS_REACT_ACT_ENVIRONMENT;
  const previousRecentFolders = useRecentFoldersStore.getState().recentFolders;
  const versionQuery = spyOn(tauriApp, "getVersion").mockResolvedValue("0.0.0");
  const workspaceId = "welcome-clone-test";
  const container = document.createElement("div");
  let root: Root | undefined;

  try {
    actEnvironment.IS_REACT_ACT_ENVIRONMENT = true;
    // Keep real module exports intact so later tests can use the same stores and locale provider.
    const uiStore = useUIState.getStore(workspaceId);
    const fileSystemStore = useFileSystemStore.getStore(workspaceId);
    const handleOpenFolder = mock(async () => false);
    fileSystemStore.setState({ handleOpenFolder });
    useRecentFoldersStore.setState({ recentFolders: [] });
    expect(fileSystemStore.getState().rootFolderPath).toBeUndefined();

    document.body.append(container);
    root = createRoot(container);
    const mountedRoot = root;
    const t = createTranslator("en-US");
    await act(async () => {
      mountedRoot.render(
        <WorkspaceStoreScopeContext.Provider value={workspaceId}>
          <LocaleProvider language="en-US">
            <WelcomeScreen />
          </LocaleProvider>
        </WorkspaceStoreScopeContext.Provider>,
      );
    });
    expect(container.textContent).toContain(t("welcome.noRecentProjects"));
    const cloneButton = Array.from(container.querySelectorAll("button")).find(
      (button) => button.textContent === t("welcome.clone"),
    );
    expect(cloneButton).toBeDefined();

    await act(async () => {
      cloneButton!.click();
    });

    const state = uiStore.getState();
    expect(state.isProjectPickerVisible).toBe(true);
    expect(getProjectPickerInitialState(state.projectPickerMode)).toEqual({
      commandStep: "newProject",
      newProjectSource: "clone",
    });
    expect(handleOpenFolder).not.toHaveBeenCalled();
  } finally {
    try {
      await act(async () => root?.unmount());
    } finally {
      container.remove();
      versionQuery.mockRestore();
      useRecentFoldersStore.setState({ recentFolders: previousRecentFolders });
      workspaceRuntimeRegistry.removeWorkspace(workspaceId);
      if (previousActEnvironment === undefined) {
        delete actEnvironment.IS_REACT_ACT_ENVIRONMENT;
      } else {
        actEnvironment.IS_REACT_ACT_ENVIRONMENT = previousActEnvironment;
      }
      restoreDom();
    }
  }
});
