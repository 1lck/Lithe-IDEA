import { useShallow } from "zustand/react/shallow";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { getFileTreeRowHeight } from "../lib/file-tree-row";

export interface FileTreePresentation {
  compactFolders: boolean;
  indentSize: number;
  rowHeight: number;
  showIcons: boolean;
  showIndentGuides: boolean;
}

export function useFileTreePresentation(): FileTreePresentation {
  const settings = useSettingsStore(
    useShallow((state) => ({
      compactFolders: state.settings.compactFoldersInFileTree,
      indentSize: state.settings.fileTreeIndentSize,
      showIcons: state.settings.showFileIconsInFileTree,
      showIndentGuides: state.settings.showIndentGuidesInFileTree,
      uiFontSize: state.settings.uiFontSize,
    })),
  );

  return {
    compactFolders: settings.compactFolders,
    indentSize: settings.indentSize,
    rowHeight: getFileTreeRowHeight(settings.uiFontSize),
    showIcons: settings.showIcons,
    showIndentGuides: settings.showIndentGuides,
  };
}
