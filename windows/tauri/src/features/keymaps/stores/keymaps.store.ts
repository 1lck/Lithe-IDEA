/**
 * Zustand store for keymaps
 * Manages keybindings and context state
 */

import { create } from "zustand";
import { persist } from "zustand/middleware";
import { createSelectors } from "@/utils/zustand-selectors";
import { KeymapContextError, prepareWhenClause } from "../utils/context";
import type { Keybinding, KeymapContext, KeymapStore } from "../types/keymaps.types";
import {
  getExportableUserKeybindings,
  normalizeUserKeybinding,
} from "../utils/keybinding-import-export";

interface KeymapState extends KeymapStore {
  recordingCommandId: string | null;
  actions: {
    addKeybinding: (keybinding: Keybinding) => Promise<void>;
    removeKeybinding: (commandId: string) => void;
    updateKeybinding: (commandId: string, updates: Partial<Keybinding>) => Promise<void>;
    resetToDefaults: () => void;
    setContext: (key: keyof KeymapContext, value: boolean) => void;
    setContexts: (contexts: Partial<KeymapContext>) => void;
    startRecording: (commandId: string) => void;
    stopRecording: () => void;
  };
}

const useKeymapStoreBase = create<KeymapState>()(
  persist(
    (set) => ({
      keybindings: [],
      recordingCommandId: null,
      contexts: {
        editorFocus: false,
        vimMode: false,
        vimNormalMode: false,
        vimInsertMode: false,
        vimVisualMode: false,
        terminalFocus: false,
        sidebarFocus: false,
        findWidgetVisible: false,
        hasSelection: false,
        isRecordingKeybinding: false,
      },
      actions: {
        addKeybinding: async (keybinding) => {
          const expected = useKeymapStoreBase.getState().keybindings;
          const userKeybinding = normalizeUserKeybinding(keybinding);
          if (!userKeybinding) return;
          if (userKeybinding.when) await prepareWhenClause(userKeybinding.when);
          if (useKeymapStoreBase.getState().keybindings !== expected)
            throw new KeymapContextError("configuration_changed");
          set((state) => ({
            keybindings: [
              ...state.keybindings.filter((kb) => kb.command !== userKeybinding.command),
              userKeybinding,
            ],
          }));
        },
        removeKeybinding: (commandId) =>
          set((state) => ({
            keybindings: state.keybindings.filter((kb) => kb.command !== commandId),
          })),
        updateKeybinding: async (commandId, updates) => {
          const expected = useKeymapStoreBase.getState().keybindings;
          const replacements = expected.map((kb) =>
            kb.command === commandId ? normalizeUserKeybinding({ ...kb, ...updates }) : kb,
          );
          for (const kb of replacements) {
            if (kb?.command === commandId) await prepareWhenClause(kb.when);
          }
          // Do not overwrite a reset, import or edit that completed during Core validation.
          if (useKeymapStoreBase.getState().keybindings !== expected)
            throw new KeymapContextError("configuration_changed");
          set(() => ({
            keybindings: replacements.filter((kb): kb is Keybinding => kb !== null),
          }));
        },
        resetToDefaults: () =>
          set(() => ({
            keybindings: [],
          })),
        setContext: (key, value) =>
          set((state) => ({
            contexts: { ...state.contexts, [key]: value },
          })),
        setContexts: (contexts) =>
          set((state) => ({
            contexts: { ...state.contexts, ...contexts },
          })),
        startRecording: (commandId) =>
          set((state) => ({
            recordingCommandId: commandId,
            contexts: { ...state.contexts, isRecordingKeybinding: true },
          })),
        stopRecording: () =>
          set((state) => ({
            recordingCommandId: null,
            contexts: { ...state.contexts, isRecordingKeybinding: false },
          })),
      },
    }),
    {
      name: "keymaps-storage",
      partialize: (state) => ({
        keybindings: getExportableUserKeybindings(state.keybindings),
      }),
    },
  ),
);

export const useKeymapStore = createSelectors(useKeymapStoreBase);
