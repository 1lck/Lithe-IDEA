import { invoke } from "@/platform/tauri-core";
import { create } from "zustand";
import { createSelectors } from "@/utils/zustand-selectors";

/**
 * Read Windows' clipboard change counter without touching the clipboard.
 *
 * The counter is the only reliable way to tell "nothing copied since the file
 * copy" from "the same text copied again", which content comparison cannot do.
 * A failed read must not break copying, so it reports "unknown".
 */
async function snapshotClipboardSequence(): Promise<number | null> {
  try {
    return await invoke<number>("clipboard_sequence_number");
  } catch {
    return null;
  }
}

export interface ClipboardEntry {
  path: string;
  is_dir: boolean;
}

export interface FileClipboardState {
  entries: ClipboardEntry[];
  operation: "copy" | "cut";
}

interface PastedEntry {
  source_path: string;
  destination_path: string;
  is_dir: boolean;
}

interface FileClipboardStore {
  clipboard: FileClipboardState | null;
  /**
   * Clipboard change counter read when the entries were copied. The terminal
   * compares it with a fresh reading to tell whether the file copy is still the
   * user's latest action; reading it never writes the clipboard.
   */
  sourceClipboardSequence: number | null;
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
  sourceClipboardSequence: null,
  actions: {
    copy: async (entries: ClipboardEntry[]) => {
      await invoke("clipboard_set", { entries, operation: "copy" });
      set({
        clipboard: { entries, operation: "copy" },
        sourceClipboardSequence: await snapshotClipboardSequence(),
      });
    },
    cut: async (entries: ClipboardEntry[]) => {
      await invoke("clipboard_set", { entries, operation: "cut" });
      set({
        clipboard: { entries, operation: "cut" },
        sourceClipboardSequence: await snapshotClipboardSequence(),
      });
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
      set({ clipboard: null, sourceClipboardSequence: null });
    },
    setClipboard: (state: FileClipboardState | null) => {
      // The counter belongs to the copy that produced this state, so a state
      // arriving from another window keeps the one already recorded here.
      set(state ? { clipboard: state } : { clipboard: null, sourceClipboardSequence: null });
    },
  },
}));

export const useFileClipboardStore = createSelectors(useFileClipboardStoreBase);
