import { createStore } from "zustand/vanilla";
import { createWorkspaceScopedStore } from "@/features/workspace/stores/create-workspace-scoped-store";
import { getPathIdentity } from "@/utils/path-helpers";

interface SavedChangesOperationsState {
  pending: ReadonlyMap<string, object>;
  startOperation: (root: string) => (() => void) | undefined;
}

/** Native operations outlive sidebar panes; their workspace owns matching release tokens. */
export const useSavedChangesOperationsStore = createWorkspaceScopedStore(
  "git-saved-changes-operations",
  () =>
    createStore<SavedChangesOperationsState>((set, get) => ({
      pending: new Map(),
      startOperation: (root) => {
        const key = getPathIdentity(root);
        if (get().pending.has(key)) return;
        const token = {};
        set({ pending: new Map(get().pending).set(key, token) });
        return () => {
          if (get().pending.get(key) !== token) return;
          const pending = new Map(get().pending);
          pending.delete(key);
          set({ pending });
        };
      },
    })),
);
