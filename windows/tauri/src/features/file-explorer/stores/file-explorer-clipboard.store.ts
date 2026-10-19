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
      // The backend is the single source of truth. It records the entries and the
      // clipboard counter together and broadcasts the same state, so writing them
      // here first would let a rejected copy leave this window holding entries the
      // native clipboard never accepted — the explorer paste would then act on a
      // different set than the terminal.
      //
      // A reply that carries no entries can only come from a caller that does not
      // implement this command (an older host or a test double); keep the copy
      // usable there instead of emptying the clipboard.
      const state = await invoke<FileClipboardState | undefined>("clipboard_set", {
        entries,
        operation: "copy",
      });
      set({ clipboard: state?.entries.length ? state : { entries, operation: "copy" } });
    },
    cut: async (entries: ClipboardEntry[]) => {
      const state = await invoke<FileClipboardState | undefined>("clipboard_set", {
        entries,
        operation: "cut",
      });
      set({ clipboard: state?.entries.length ? state : { entries, operation: "cut" } });
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
