import type { EditorContent } from "@/features/panes/types/pane-content.types";
import { createTranslator } from "@/i18n/locale";
import { useSettingsStore } from "@/features/settings/stores/settings.store";

/** Legacy buffers without a restore state already contain their document. */
export function isBufferContentLoaded(buffer: Pick<EditorContent, "loadState">): boolean {
  return buffer.loadState === undefined || buffer.loadState === "loaded";
}

export function requireLoadedBufferContent(buffer: EditorContent): void {
  if (!isBufferContentLoaded(buffer)) {
    throw new Error(bufferNotLoadedMessage(buffer.name));
  }
}

export function bufferNotLoadedMessage(name: string): string {
  const t = createTranslator(useSettingsStore.getState().settings.displayLanguage);
  return t("editor.contentNotLoaded", { name });
}
