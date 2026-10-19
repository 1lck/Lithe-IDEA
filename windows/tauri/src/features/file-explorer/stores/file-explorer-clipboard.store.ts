import { invoke } from "@/platform/tauri-core";
import { create } from "zustand";
import { createSelectors } from "@/utils/zustand-selectors";

export interface ClipboardEntry {
  path: string;
  is_dir: boolean;
}

export interface FileClipboardState {
  entries: ClipboardEntry[];
  operation: "copy" | "cut";
  /** Clipboard change counter captured by the copy that produced this state. */
  source_sequence?: number | null;
}

interface PastedEntry {
  source_path: string;
  destination_path: string;
  is_dir: boolean;
}

interface FileClipboardStore {
  clipboard: FileClipboardState | null;
  actions: {
    copy: (entries: ClipboardEntry[]) => Promise<void>;
    cut: (entries: ClipboardEntry[]) => Promise<void>;
    paste: (targetDirectory: string) => Promise<PastedEntry[]>;
    clear: () => Promise<void>;
    setClipboard: (state: FileClipboardState | null) => void;
  };
}

const useFileClipboardStoreBase = create<FileClipboardStore>()((set) => ({
  clipboard: null,
  actions: {
    copy: async (entries: ClipboardEntry[]) => {
      // Record locally first: the entries must survive regardless of how the
      // backend call behaves, because the terminal reads them from this store.
      set({ clipboard: { entries, operation: "copy" } });
      // Then adopt the state the backend recorded, which carries the clipboard
      // counter so every window compares against the copy that produced these
      // entries. The attempt is best-effort on purpose — a failed or unexpected
      // reply must not erase what the user just copied.
      try {
        const state = await invoke<FileClipboardState | undefined>("clipboard_set", {
          entries,
          operation: "copy",
        });
        if (state?.entries.length) set({ clipboard: state });
      } catch (error) {
        console.error("File clipboard copy could not be synchronized:", error);
      }
    },
    cut: async (entries: ClipboardEntry[]) => {
      set({ clipboard: { entries, operation: "cut" } });
      try {
        const state = await invoke<FileClipboardState | undefined>("clipboard_set", {
          entries,
          operation: "cut",
        });
        if (state?.entries.length) set({ clipboard: state });
      } catch (error) {
        console.error("File clipboard cut could not be synchronized:", error);
      }
    },
    paste: async (targetDirectory: string) => {
      const result = await invoke<PastedEntry[]>("clipboard_paste", {
        targetDirectory,
      });
      // Backend updates clipboard state and emits events; sync eagerly
      const clipboard = await invoke<FileClipboardState | null>("clipboard_get");
      set({ clipboard });
      return result;
    },
    clear: async () => {
      await invoke("clipboard_clear");
      set({ clipboard: null });
    },
    setClipboard: (state: FileClipboardState | null) => {
      // The counter travels inside the state, so a copy received from another
      // window replaces it together with the entries it describes.
      set({ clipboard: state });
    },
  },
}));

export const useFileClipboardStore = createSelectors(useFileClipboardStoreBase);
