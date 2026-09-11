import { create } from "zustand";
import { persist } from "zustand/middleware";
import { createSelectors } from "@/utils/zustand-selectors";
import { createSafeJSONStorage } from "@/utils/zustand-storage";
import { RUN_CONFIGURATION_LIST_DEFAULT_WIDTH } from "../utils/run-configuration-list-layout";

interface RunPreferencesStore {
  configurationListWidth: number;
  selectedServiceIDsByWorkspace: Record<string, string[]>;
  actions: {
    setConfigurationListWidth: (width: number) => void;
    setSelectedServiceIDs: (workspace: string, ids: string[]) => void;
  };
}

const useRunPreferencesStoreBase = create<RunPreferencesStore>()(
  persist(
    (set) => ({
      configurationListWidth: RUN_CONFIGURATION_LIST_DEFAULT_WIDTH,
      selectedServiceIDsByWorkspace: {},
      actions: {
        setConfigurationListWidth: (configurationListWidth) => set({ configurationListWidth }),
        setSelectedServiceIDs: (workspace, ids) =>
          set((state) => ({
            selectedServiceIDsByWorkspace: {
              ...state.selectedServiceIDsByWorkspace,
              [workspace]: ids,
            },
          })),
      },
    }),
    {
      name: "lithe-run-preferences",
      storage: createSafeJSONStorage<Omit<RunPreferencesStore, "actions">>(),
      partialize: ({ actions: _, ...preferences }) => preferences,
      merge: (persistedState, currentState) => ({
        ...currentState,
        ...(persistedState as Partial<RunPreferencesStore>),
        actions: currentState.actions,
      }),
    },
  ),
);

export const useRunPreferencesStore = createSelectors(useRunPreferencesStoreBase);
