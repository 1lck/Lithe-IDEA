import { describe, expect, test } from "bun:test";
import { createStore } from "zustand/vanilla";
import { getProjectPickerInitialState } from "@/features/window/utils/project-picker-mode";
import { createModalSlice, type ModalSlice } from "./modal-slice";

describe("project picker modal", () => {
  test("opens the requested form and closes the previous modal in one update", () => {
    const store = createStore<ModalSlice>()(createModalSlice);
    store.getState().setIsQuickOpenVisible(true);
    store.getState().setIsProjectPickerVisible(true, "clone-repository");

    const state = store.getState();
    expect(state.isProjectPickerVisible).toBe(true);
    expect(state.isQuickOpenVisible).toBe(false);
    expect(getProjectPickerInitialState(state.projectPickerMode)).toEqual({
      commandStep: "newProject",
      newProjectSource: "clone",
    });
  });

  test("returns to the regular picker after closing the clone form", () => {
    const store = createStore<ModalSlice>()(createModalSlice);
    store.getState().setIsProjectPickerVisible(true, "clone-repository");
    store.getState().setIsProjectPickerVisible(false);
    expect(store.getState().isProjectPickerVisible).toBe(false);
    expect(store.getState().projectPickerMode).toBe("picker");

    store.getState().setIsProjectPickerVisible(true);
    expect(getProjectPickerInitialState(store.getState().projectPickerMode)).toEqual({
      commandStep: "picker",
      newProjectSource: undefined,
    });
  });

  test("clears the clone mode when dismissed through the modal keyboard action", () => {
    const store = createStore<ModalSlice>()(createModalSlice);
    store.getState().setIsProjectPickerVisible(true, "clone-repository");

    expect(store.getState().closeTopModal()).toBe(true);
    expect(store.getState().hasOpenModal()).toBe(false);
    expect(store.getState().projectPickerMode).toBe("picker");
  });

  test("selects new-project mode after another dialog dismisses the clone form", () => {
    const store = createStore<ModalSlice>()(createModalSlice);
    store.getState().setIsProjectPickerVisible(true, "clone-repository");
    store.getState().openSettingsDialog();
    store.getState().setIsProjectPickerVisible(true, "new-project");

    expect(store.getState().isSettingsDialogVisible).toBe(false);
    expect(getProjectPickerInitialState(store.getState().projectPickerMode)).toEqual({
      commandStep: "newProject",
      newProjectSource: undefined,
    });
  });
});
