import { createStore } from "zustand/vanilla";
import type { Terminal } from "@/features/terminal/types/terminal.types";
import { createWorkspaceScopedStore } from "@/features/workspace/stores/create-workspace-scoped-store";

export type TerminalWidthMode = "full" | "editor";
export type TerminalTabLayout = "horizontal" | "vertical";
export type TerminalTabSidebarPosition = "left" | "right";

export interface TerminalStore {
  sessions: Map<string, Partial<Terminal>>;
  widthMode: TerminalWidthMode;
  tabLayout: TerminalTabLayout;
  tabSidebarWidth: number;
  tabSidebarPosition: TerminalTabSidebarPosition;
  actions: {
    updateSession: (sessionId: string, updates: Partial<Terminal>) => void;
    getSession: (sessionId: string) => Partial<Terminal> | undefined;
    removeSession: (sessionId: string) => void;
    setWidthMode: (mode: TerminalWidthMode) => void;
    setTabLayout: (layout: TerminalTabLayout) => void;
    setTabSidebarWidth: (width: number) => void;
    setTabSidebarPosition: (position: TerminalTabSidebarPosition) => void;
  };
}

// Matches the IDEA default: the bottom tool window spans the full workbench width and the
// sidebar yields vertical space to it, instead of staying full height beside the panel.
export const DEFAULT_TERMINAL_WIDTH_MODE: TerminalWidthMode = "full";

export const createTerminalStore = () =>
  createStore<TerminalStore>()((set, get) => ({
    sessions: new Map(),
    widthMode: DEFAULT_TERMINAL_WIDTH_MODE,
    tabLayout: "horizontal",
    tabSidebarWidth: 180,
    tabSidebarPosition: "left",

    actions: {
      updateSession: (sessionId: string, updates: Partial<Terminal>) => {
        set((state) => {
          const newSessions = new Map(state.sessions);
          const currentSession = newSessions.get(sessionId) || {};
          newSessions.set(sessionId, { ...currentSession, ...updates });
          return { sessions: newSessions };
        });
      },

      getSession: (sessionId: string) => {
        return get().sessions.get(sessionId);
      },

      removeSession: (sessionId: string) => {
        set((state) => {
          const newSessions = new Map(state.sessions);
          newSessions.delete(sessionId);
          return { sessions: newSessions };
        });
      },

      setWidthMode: (mode: TerminalWidthMode) => {
        set({ widthMode: mode });
      },

      setTabLayout: (tabLayout: TerminalTabLayout) => {
        set({ tabLayout });
      },

      setTabSidebarWidth: (tabSidebarWidth: number) => {
        set({ tabSidebarWidth: Math.max(80, Math.min(400, tabSidebarWidth)) });
      },

      setTabSidebarPosition: (tabSidebarPosition: TerminalTabSidebarPosition) => {
        set({ tabSidebarPosition });
      },
    },
  }));

export const useTerminalStore = createWorkspaceScopedStore("terminal", createTerminalStore);
