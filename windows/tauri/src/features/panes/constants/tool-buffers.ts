import type { TranslationKey } from "@/i18n/locale";
import type { PaneContent, PaneContentType } from "@/features/panes/types/pane-content.types";

export type SingletonToolBufferType = Extract<
  PaneContentType,
  "globalSearch" | "diagnostics" | "references" | "extensions"
>;

export const SINGLETON_TOOL_BUFFER_METADATA: Record<
  SingletonToolBufferType,
  { path: string; name: string; titleKey: TranslationKey }
> = {
  globalSearch: {
    path: "search://global",
    name: "Search",
    titleKey: "workbench.search",
  },
  diagnostics: {
    path: "diagnostics://problems",
    name: "Diagnostics",
    titleKey: "workbench.diagnostics",
  },
  references: {
    path: "references://results",
    name: "References",
    titleKey: "references.title",
  },
  extensions: {
    path: "extensions://marketplace",
    name: "Extensions",
    titleKey: "extensions.title",
  },
};

function isSingletonToolBufferType(type: PaneContentType): type is SingletonToolBufferType {
  return type in SINGLETON_TOOL_BUFFER_METADATA;
}

export function getSingletonToolBufferTitleKey(type: PaneContentType): TranslationKey | null {
  return isSingletonToolBufferType(type) ? SINGLETON_TOOL_BUFFER_METADATA[type].titleKey : null;
}

export function isSingletonToolBuffer(buffer: PaneContent): boolean {
  return isSingletonToolBufferType(buffer.type);
}
