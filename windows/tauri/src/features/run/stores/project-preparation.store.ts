import { createStore } from "zustand/vanilla";
import { useStore } from "zustand";

export interface ProjectPreparation {
  phase: "starting" | "importing" | "configuring" | "building" | "ready" | "stopped";
  status: "idle" | "loading" | "ready" | "failed";
  blocksRun: boolean;
}
export interface PreparationEntry extends ProjectPreparation {
  sessionId: string;
}
const key = (root: string) => root.replace(/\\/g, "/").replace(/\/+$/, "").toLowerCase();

export const projectPreparationStore = createStore<{ entries: Record<string, PreparationEntry> }>(
  () => ({ entries: {} }),
);

export function beginProjectPreparation(root: string, sessionId: string) {
  projectPreparationStore.setState((state) => ({
    entries: {
      ...state.entries,
      [key(root)]: { sessionId, phase: "starting", status: "loading", blocksRun: true },
    },
  }));
}
export function updateProjectPreparation(
  root: string,
  sessionId: string,
  value: ProjectPreparation,
) {
  projectPreparationStore.setState((state) =>
    state.entries[key(root)]?.sessionId !== sessionId
      ? state
      : {
          entries: { ...state.entries, [key(root)]: { ...value, sessionId } },
        },
  );
}
export function clearProjectPreparation(root: string, sessionId: string) {
  projectPreparationStore.setState((state) => {
    if (state.entries[key(root)]?.sessionId !== sessionId) return state;
    const entries = { ...state.entries };
    delete entries[key(root)];
    return { entries };
  });
}
export function getProjectPreparation(root: string) {
  return projectPreparationStore.getState().entries[key(root)];
}
export function useProjectPreparation(root: string | null | undefined) {
  return useStore(projectPreparationStore, (state) =>
    root ? state.entries[key(root)] : undefined,
  );
}
