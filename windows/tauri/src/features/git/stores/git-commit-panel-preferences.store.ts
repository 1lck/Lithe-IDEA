import { create } from "zustand";
import { persist } from "zustand/middleware";
import { createSelectors } from "@/utils/zustand-selectors";
import { createSafeJSONStorage } from "@/utils/zustand-storage";

/** Commit message editor height bounds in CSS pixels. */
export const COMMIT_MESSAGE_MIN_HEIGHT = 48;
export const COMMIT_MESSAGE_DEFAULT_HEIGHT = 72;
export const COMMIT_MESSAGE_MAX_HEIGHT = 640;

export function clampCommitMessageHeight(height: number): number {
  if (!Number.isFinite(height)) return COMMIT_MESSAGE_DEFAULT_HEIGHT;
  return Math.round(Math.min(COMMIT_MESSAGE_MAX_HEIGHT, Math.max(COMMIT_MESSAGE_MIN_HEIGHT, height)));
}

interface GitCommitPanelPreferencesStore {
  // Set by dragging the divider above the commit area, like IntelliJ's
  // changes/commit splitter; the changes list takes the remaining height.
  commitMessageHeight: number;
  actions: {
    /** Persists the editor height; call once when a drag ends, not per pointer move. */
    setCommitMessageHeight: (height: number) => void;
  };
}

type PersistedPreferences = Pick<GitCommitPanelPreferencesStore, "commitMessageHeight">;

const useGitCommitPanelPreferencesStoreBase = create<GitCommitPanelPreferencesStore>()(
  persist(
    (set) => ({
      commitMessageHeight: COMMIT_MESSAGE_DEFAULT_HEIGHT,
      actions: {
        setCommitMessageHeight: (height) =>
          set({ commitMessageHeight: clampCommitMessageHeight(height) }),
      },
    }),
    {
      name: "git-commit-panel-preferences",
      storage: createSafeJSONStorage<PersistedPreferences>(),
      partialize: ({ commitMessageHeight }) => ({ commitMessageHeight }),
      merge: (persistedState, currentState) => {
        const persisted = persistedState as Partial<PersistedPreferences> | undefined;
        return {
          ...currentState,
          commitMessageHeight:
            typeof persisted?.commitMessageHeight === "number"
              ? clampCommitMessageHeight(persisted.commitMessageHeight)
              : currentState.commitMessageHeight,
          actions: currentState.actions,
        };
      },
    },
  ),
);

export const useGitCommitPanelPreferencesStore = createSelectors(
  useGitCommitPanelPreferencesStoreBase,
);
