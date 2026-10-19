import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { useLocalHistoryStore } from "@/features/local-history/stores/local-history.store";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { createTranslator } from "@/i18n/locale";
import { toast } from "sonner";

const getCurrentTranslator = () =>
  createTranslator(useSettingsStore.getState().settings.displayLanguage);

export function openLocalHistoryForPath(
  path: string | null | undefined,
  selectedEntryId?: string,
): void {
  if (!path || path.includes("://")) {
    toast.warning(getCurrentTranslator()("localHistory.selectLocalFileFirst"));
    return;
  }

  useLocalHistoryStore.getState().actions.setTargetPath(path, false, selectedEntryId);
  useUIState.getState().openCommandPaletteView("local-history");
}

export function openLocalHistoryForActiveFile(): void {
  const bufferStore = useBufferStore.getState();
  const activeBuffer = bufferStore.buffers.find(
    (buffer) => buffer.id === bufferStore.activeBufferId,
  );

  if (!activeBuffer || activeBuffer.type !== "editor" || activeBuffer.isVirtual) {
    toast.warning(getCurrentTranslator()("localHistory.openLocalFileFirst"));
    return;
  }

  openLocalHistoryForPath(activeBuffer.path);
}

export function canOpenProjectLocalHistory(path: string | null | undefined): path is string {
  return Boolean(path && !path.includes("://"));
}

export function openProjectLocalHistory(workspaceRoot: string): void {
  if (!canOpenProjectLocalHistory(workspaceRoot)) {
    toast.warning(getCurrentTranslator()("localHistory.localWorkspaceOnly"));
    return;
  }
  useLocalHistoryStore.getState().actions.setTargetPath(workspaceRoot, true);
  useUIState.getState().openCommandPaletteView("local-history");
}
