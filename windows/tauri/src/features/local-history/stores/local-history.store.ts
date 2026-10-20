import { create } from "zustand";
import { createSelectors } from "@/utils/zustand-selectors";

interface LocalHistoryState {
  targetPath: string | null;
  project: boolean;
  selectedEntryId: string | null;
  actions: {
    setTargetPath: (path: string | null, project?: boolean, selectedEntryId?: string) => void;
  };
}

export const useLocalHistoryStore = createSelectors(
  create<LocalHistoryState>()((set) => ({
    targetPath: null,
    project: false,
    selectedEntryId: null,
    actions: {
      setTargetPath: (path, project = false, selectedEntryId) => set({ targetPath: path, project, selectedEntryId: selectedEntryId ?? null }),
    },
  })),
);
