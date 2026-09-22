import { create } from "zustand";
import { persist } from "zustand/middleware";
import { createSelectors } from "@/utils/zustand-selectors";
import { createSafeJSONStorage } from "@/utils/zustand-storage";
import { RUN_CONFIGURATION_LIST_DEFAULT_WIDTH } from "../utils/run-configuration-list-layout";

export type JavaBuildFailurePolicy = "ask" | "alwaysProceed";

interface RunPreferencesStore {
  configurationListWidth: number;
  scrollOutputToEnd: boolean;
  selectedServiceIDsByWorkspace: Record<string, string[]>;
  javaBuildFailurePolicyByWorkspace: Record<string, JavaBuildFailurePolicy>;
  actions: {
    setConfigurationListWidth: (width: number) => void;
    setScrollOutputToEnd: (scroll: boolean) => void;
    setSelectedServiceIDs: (workspace: string, ids: string[]) => void;
    setJavaBuildFailurePolicy: (workspace: string, policy: JavaBuildFailurePolicy) => void;
  };
}

export const runWorkspacePreferenceKey = (workspace: string) =>
  workspace.replace(/\\/g, "/").replace(/\/+$/, "").toLowerCase();

const useRunPreferencesStoreBase = create<RunPreferencesStore>()(
  persist(
    (set) => ({
      configurationListWidth: RUN_CONFIGURATION_LIST_DEFAULT_WIDTH,
      scrollOutputToEnd: true,
      selectedServiceIDsByWorkspace: {},
      javaBuildFailurePolicyByWorkspace: {},
      actions: {
        setConfigurationListWidth: (configurationListWidth) => set({ configurationListWidth }),
        setScrollOutputToEnd: (scrollOutputToEnd) => set({ scrollOutputToEnd }),
        setSelectedServiceIDs: (workspace, ids) =>
          set((state) => ({
            selectedServiceIDsByWorkspace: {
              ...state.selectedServiceIDsByWorkspace,
              [workspace]: ids,
            },
          })),
        setJavaBuildFailurePolicy: (workspace, policy) =>
          set((state) => ({
            javaBuildFailurePolicyByWorkspace: {
              ...state.javaBuildFailurePolicyByWorkspace,
              [runWorkspacePreferenceKey(workspace)]: policy,
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

export function javaBuildFailurePolicyForWorkspace(workspace: string): JavaBuildFailurePolicy {
  return (
    useRunPreferencesStore.getState().javaBuildFailurePolicyByWorkspace[
      runWorkspacePreferenceKey(workspace)
    ] ?? "ask"
  );
}
