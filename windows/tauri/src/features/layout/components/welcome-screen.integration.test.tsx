import { afterAll, expect, mock, test } from "bun:test";
import { act, type ComponentProps } from "react";
import { createRoot } from "react-dom/client";
import { useStore } from "zustand";
import { createStore } from "zustand/vanilla";
import { createModalSlice, type ModalSlice } from "@/features/window/stores/ui-state/modal-slice";
import { getProjectPickerInitialState } from "@/features/window/utils/project-picker-mode";
import { installHappyDom } from "@/test-utils/happy-dom";

const restoreDom = installHappyDom();
const actEnvironment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
const previousActEnvironment = actEnvironment.IS_REACT_ACT_ENVIRONMENT;
actEnvironment.IS_REACT_ACT_ENVIRONMENT = true;

const uiStore = createStore<ModalSlice>()(createModalSlice);
const fileSystemState = { rootFolderPath: null, handleOpenFolder: mock(async () => {}) };
const recentFoldersState = {
  recentFolders: [],
  actions: { openRecentFolder: mock(async () => {}), removeFromRecents: mock(() => {}) },
};

mock.module("@tauri-apps/api/app", () => ({ getVersion: async () => "0.0.0" }));
mock.module("@/features/window/stores/ui-state.store", () => ({
  useUIState: <Value,>(selector: (state: ModalSlice) => Value) => useStore(uiStore, selector),
}));
mock.module("@/features/file-system/stores/file-system.store", () => ({
  useFileSystemStore: <Value,>(selector: (state: typeof fileSystemState) => Value) =>
    selector(fileSystemState),
}));
mock.module("@/features/file-system/stores/recent-folders.store", () => ({
  useRecentFoldersStore: <Value,>(selector: (state: typeof recentFoldersState) => Value) =>
    selector(recentFoldersState),
}));
mock.module("@/i18n/locale-provider", () => ({
  useTranslation: () => ({ t: (key: string) => key }),
}));
mock.module("@/ui/button", () => ({
  Button: ({ variant: _variant, size: _size, ...props }: ComponentProps<"button"> & {
    variant?: string;
    size?: string;
  }) => <button {...props} />,
}));

const { WelcomeScreen } = await import("./welcome-screen");

afterAll(() => {
  if (previousActEnvironment === undefined) {
    delete actEnvironment.IS_REACT_ACT_ENVIRONMENT;
  } else {
    actEnvironment.IS_REACT_ACT_ENVIRONMENT = previousActEnvironment;
  }
  restoreDom();
});

test("welcome Clone opens repository details with no open or recent project", async () => {
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);

  try {
    await act(async () => {
      root.render(<WelcomeScreen />);
    });
    expect(container.textContent).toContain("welcome.noRecentProjects");
    const cloneButton = Array.from(container.querySelectorAll("button")).find(
      (button) => button.textContent === "welcome.clone",
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
    expect(fileSystemState.handleOpenFolder).not.toHaveBeenCalled();
  } finally {
    await act(async () => root.unmount());
    container.remove();
    uiStore.getState().setIsProjectPickerVisible(false);
  }
});
