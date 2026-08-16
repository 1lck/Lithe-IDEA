import { create } from "zustand";
import { persist } from "zustand/middleware";
import { createSelectors } from "@/utils/zustand-selectors";
import { createSafeJSONStorage } from "@/utils/zustand-storage";

export type GitDiffViewMode = "unified" | "split";

interface GitDiffPreferencesStore {
  // Split matches the macOS reference product and IDEA; users who prefer the
  // unified layout switch once and the choice persists across sessions.
  viewMode: GitDiffViewMode;
  actions: {
    setViewMode: (mode: GitDiffViewMode) => void;
  };
}

const useGitDiffPreferencesStoreBase = create<GitDiffPreferencesStore>()(
  persist(
    (set) => ({
      viewMode: "split",

      actions: {
        setViewMode: (viewMode) => set({ viewMode }),
      },
    }),
    {
      name: "git-diff-preferences",
      storage: createSafeJSONStorage<Pick<GitDiffPreferencesStore, "viewMode">>(),
      partialize: ({ viewMode }) => ({ viewMode }),
      merge: (persistedState, currentState) => ({
        ...currentState,
        ...(persistedState as Pick<GitDiffPreferencesStore, "viewMode">),
        actions: currentState.actions,
      }),
    },
  ),
);

export const useGitDiffPreferencesStore = createSelectors(useGitDiffPreferencesStoreBase);
