import { createStore } from "zustand/vanilla";
import { createWorkspaceScopedStore } from "@/features/workspace/stores/create-workspace-scoped-store";
import {
  EMPTY_SPRING_INDEX,
  type SpringIndex,
  type SpringIndexError,
  type SpringIndexPhase,
} from "../types/spring.types";
import { isSameSpringRoot } from "../utils/spring-root";

interface SpringState {
  requestedRoot: string | null;
  loadedRoot: string | null;
  root: string | null;
  index: SpringIndex;
  phase: SpringIndexPhase;
  error: SpringIndexError | null;
  isIndexing: boolean;
  generation: number;
  actions: {
    beginLoad: (root: string) => number;
    completeLoad: (generation: number, root: string, index: SpringIndex) => void;
    failLoad: (generation: number, error: SpringIndexError) => void;
    reset: () => void;
  };
}

const createSpringStore = () =>
  createStore<SpringState>()((set, get) => ({
    requestedRoot: null,
    loadedRoot: null,
    root: null,
    index: EMPTY_SPRING_INDEX,
    phase: "idle",
    error: null,
    isIndexing: false,
    generation: 0,
    actions: {
      beginLoad: (root) => {
        const generation = get().generation + 1;
        const rootChanged = !isSameSpringRoot(get().requestedRoot, root);
        set({
          requestedRoot: root,
          root,
          generation,
          phase: "loading",
          error: null,
          isIndexing: true,
          ...(rootChanged
            ? {
                loadedRoot: null,
                index: EMPTY_SPRING_INDEX,
              }
            : {}),
        });
        return generation;
      },
      completeLoad: (generation, root, index) => {
        if (get().generation !== generation) return;
        set({
          requestedRoot: root,
          loadedRoot: root,
          root,
          index,
          phase: "ready",
          error: null,
          isIndexing: false,
        });
      },
      failLoad: (generation, error) => {
        if (get().generation !== generation) return;
        set({
          phase: "failed",
          error,
          isIndexing: false,
        });
      },
      reset: () => {
        set({
          requestedRoot: null,
          loadedRoot: null,
          root: null,
          index: EMPTY_SPRING_INDEX,
          phase: "idle",
          error: null,
          isIndexing: false,
          generation: get().generation + 1,
        });
      },
    },
  }));

export const useSpringStore = createWorkspaceScopedStore("spring", createSpringStore);
