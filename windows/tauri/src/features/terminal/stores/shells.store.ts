import { invoke } from "@/platform/tauri-core";
import { create } from "zustand";
import { createSelectors } from "@/utils/zustand-selectors";
import type { Shell } from "../types/terminal.types";

interface TerminalShellsState {
  shells: Shell[];
  isLoading: boolean;
  hasLoaded: boolean;
  error: string | null;
  actions: {
    loadShells: (options?: { force?: boolean }) => Promise<void>;
  };
}

export const createTerminalShellsStore = (discover: () => Promise<Shell[]>) =>
  create<TerminalShellsState>()((set, get) => ({
    shells: [],
    isLoading: false,
    hasLoaded: false,
    error: null,
    actions: {
      loadShells: async (options) => {
        const { isLoading, hasLoaded } = get();
        if (isLoading || (hasLoaded && !options?.force)) return;

        set({ isLoading: true, error: null });

        try {
          const shells = await discover();
          set({
            shells,
            isLoading: false,
            hasLoaded: true,
          });
        } catch (error) {
          console.error("Failed to load terminal shells:", error);
          set({
            isLoading: false,
            error: String(error),
          });
        }
      },
    },
  }));

export const useTerminalShellsStore = createSelectors(
  createTerminalShellsStore(() => invoke<Shell[]>("list_shells")),
);
