import { create } from "zustand";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";

export type NewEntryKind = "java" | "package" | "module";
interface NewEntryRequest {
  kind: NewEntryKind;
  directory: string;
  workspaceRoot: string;
  sourceRoot: string;
}
export const useNewEntryStore = create<{ request: NewEntryRequest | null }>(() => ({
  request: null,
}));
export function openNewEntry(kind: NewEntryKind, directory?: string, sourceRoot?: string): boolean {
  // The primary root owns this workspace; an attached module may supply a
  // different source root for package inference and the suggested parent.
  const root = useFileSystemStore.getState().rootFolderPath;
  if (!root) return false;
  const source = sourceRoot ?? root;
  const target = directory ?? source;
  if ([root, source, target].some((path) => /^(?:remote|wsl):\/\//.test(path))) return false;
  useNewEntryStore.setState({
    request: { kind, directory: target, workspaceRoot: root, sourceRoot: source },
  });
  return true;
}
