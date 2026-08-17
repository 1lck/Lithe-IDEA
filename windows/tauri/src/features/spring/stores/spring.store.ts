import { createStore } from "zustand/vanilla";
import { createWorkspaceScopedStore } from "@/features/workspace/stores/create-workspace-scoped-store";
import { EMPTY_SPRING_INDEX, type SpringIndex } from "../types/spring.types";

interface SpringState {
  root: string | null;
  index: SpringIndex;
  isIndexing: boolean;
  generation: number;
  actions: {
    beginLoad: (root: string) => number;
    completeLoad: (generation: number, root: string, index: SpringIndex) => void;
    failLoad: (generation: number) => void;
    reset: () => void;
  };
}

const createSpringStore = () =>
  createStore<SpringState>()((set, get) => ({
    root: null,
    index: EMPTY_SPRING_INDEX,
    isIndexing: false,
    generation: 0,
    actions: {
      beginLoad: (root) => {
        const generation = get().generation + 1;
        set({
          root,
          generation,
          isIndexing: true,
        });
        return generation;
      },
      completeLoad: (generation, root, index) => {
        if (get().generation !== generation) return;
        set({
          root,
          index,
          isIndexing: false,
        });
      },
      failLoad: (generation) => {
        if (get().generation !== generation) return;
        set({ isIndexing: false });
      },
      reset: () => {
        set({
          root: null,
          index: EMPTY_SPRING_INDEX,
          isIndexing: false,
          generation: get().generation + 1,
        });
      },
    },
  }));

export const useSpringStore = createWorkspaceScopedStore("spring", createSpringStore);
