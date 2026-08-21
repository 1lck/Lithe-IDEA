import { useMemo } from "react";
import { useShallow } from "zustand/react/shallow";
import { IDEA_ICON_THEME_ID } from "@/extensions/icon-themes/file-icon-semantics";
import { getFileTreeRowHeight } from "@/features/file-explorer/lib/file-tree-row";
import { buildMavenDirectorySemantics } from "@/features/file-explorer/lib/maven-file-tree-semantics";
import {
  buildVisibleFileTreeRows,
  type VisibleFileTreeRow,
} from "@/features/file-explorer/lib/visible-file-tree-rows";
import { useFileTreeStore } from "@/features/file-explorer/stores/file-explorer-tree.store";
import type { FileEntry } from "@/features/file-system/types/app.types";
import { useSettingsStore } from "@/features/settings/stores/settings.store";

interface UseFileExplorerVisibleRowsOptions {
  files: FileEntry[];
  semanticFiles?: FileEntry[];
  expandedPathsOverride?: ReadonlySet<string>;
  rootFolderPath?: string;
}

export function getVisibleFileTreeRowKey(rows: readonly VisibleFileTreeRow[], index: number) {
  return rows[index]?.file.path ?? index;
}

export function useFileExplorerVisibleRows({
  files,
  semanticFiles,
  expandedPathsOverride,
  rootFolderPath,
}: UseFileExplorerVisibleRowsOptions) {
  const expandedPaths = useFileTreeStore((state) => state.expandedPaths);
  const { compactFolders, hideRootFolder, iconTheme, showFileIcons, sortOrder, uiFontSize } =
    useSettingsStore(
      useShallow((state) => ({
        compactFolders: state.settings.compactFoldersInFileTree,
        hideRootFolder: state.settings.hideRootFolderInFileTree,
        iconTheme: state.settings.iconTheme,
        showFileIcons: state.settings.showFileIconsInFileTree,
        sortOrder: state.settings.fileTreeSortOrder,
        uiFontSize: state.settings.uiFontSize,
      })),
    );
  const rowHeight = getFileTreeRowHeight(uiFontSize);
  const semanticPresentationEnabled = showFileIcons && iconTheme === IDEA_ICON_THEME_ID;
  const directorySemantics = useMemo(
    () =>
      semanticPresentationEnabled
        ? buildMavenDirectorySemantics(semanticFiles ?? files)
        : new Map(),
    [files, semanticFiles, semanticPresentationEnabled],
  );

  const visibleRows = useMemo(() => {
    return buildVisibleFileTreeRows(files, expandedPathsOverride ?? expandedPaths, {
      compactFolders,
      directorySemantics,
      hiddenRootPath: hideRootFolder ? rootFolderPath : undefined,
      sortOrder,
    });
  }, [
    compactFolders,
    directorySemantics,
    expandedPaths,
    expandedPathsOverride,
    files,
    hideRootFolder,
    rootFolderPath,
    sortOrder,
  ]);
  const visibleRowIndexByPath = useMemo(() => {
    const indexByPath = new Map<string, number>();
    for (let index = 0; index < visibleRows.length; index++) {
      const row = visibleRows[index];
      if (row) {
        indexByPath.set(row.file.path, index);
      }
    }
    return indexByPath;
  }, [visibleRows]);
  return { rowHeight, visibleRows, visibleRowIndexByPath };
}
