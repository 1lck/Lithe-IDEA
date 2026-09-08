import { createStore } from "zustand/vanilla";
import { createWorkspaceScopedStore } from "@/features/workspace/stores/create-workspace-scoped-store";
import { EMPTY_MYBATIS_INDEX, type MybatisIndex } from "../types/mybatis.types";

interface MybatisState {
  root: string | null;
  index: MybatisIndex;
  isIndexing: boolean;
  generation: number;
  actions: {
    beginLoad: (root: string) => number;
    completeLoad: (generation: number, root: string, index: MybatisIndex) => void;
    failLoad: (generation: number) => void;
    reset: () => void;
  };
}

const createMybatisStore = () =>
  createStore<MybatisState>()((set, get) => ({
    root: null,
    index: EMPTY_MYBATIS_INDEX,
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
          index: EMPTY_MYBATIS_INDEX,
          isIndexing: false,
          generation: get().generation + 1,
        });
      },
    },
  }));

export const useMybatisStore = createWorkspaceScopedStore("mybatis", createMybatisStore);
