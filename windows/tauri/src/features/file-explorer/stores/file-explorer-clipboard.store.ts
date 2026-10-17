import { invoke } from "@/platform/tauri-core";
import { create } from "zustand";
import { createSelectors } from "@/utils/zustand-selectors";
import { readClipboardText } from "@/utils/clipboard";

/**
 * Record what the system clipboard held when files were copied, without
 * writing it. A failed read must not break copying, so it reports "unknown".
 */
async function snapshotClipboardText(): Promise<string | null> {
  try {
    return await readClipboardText();
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
   * System clipboard text observed when the entries were copied. The terminal
   * compares it with the current clipboard to tell whether the file copy is
   * still the user's latest action; reading it never writes the clipboard.
   */
  sourceClipboardText: string | null;
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
  sourceClipboardText: null,
  actions: {
    copy: async (entries: ClipboardEntry[]) => {
      await invoke("clipboard_set", { entries, operation: "copy" });
      set({ clipboard: { entries, operation: "copy" }, sourceClipboardText: await snapshotClipboardText() });
    },
    cut: async (entries: ClipboardEntry[]) => {
      await invoke("clipboard_set", { entries, operation: "cut" });
      set({ clipboard: { entries, operation: "cut" }, sourceClipboardText: await snapshotClipboardText() });
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
      set({ clipboard: null, sourceClipboardText: null });
    },
    setClipboard: (state: FileClipboardState | null) => {
      set(state ? { clipboard: state } : { clipboard: null, sourceClipboardText: null });
    },
  },
}));

export const useFileClipboardStore = createSelectors(useFileClipboardStoreBase);
