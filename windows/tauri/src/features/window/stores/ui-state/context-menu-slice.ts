import type { StateCreator } from "zustand";

interface ContextMenuState {
  folderHeaderContextMenu: { x: number; y: number } | null;
  projectNameMenu: { x: number; y: number } | null;
}

interface ContextMenuActions {
  setProjectNameMenu: (v: { x: number; y: number } | null) => void;
}

export type ContextMenuSlice = ContextMenuState & ContextMenuActions;

export const createContextMenuSlice: StateCreator<ContextMenuSlice, [], [], ContextMenuSlice> = (
  set,
) => ({
  // State
  folderHeaderContextMenu: null,
  projectNameMenu: null,

  // Actions
  setProjectNameMenu: (v: { x: number; y: number } | null) => set({ projectNameMenu: v }),
});
