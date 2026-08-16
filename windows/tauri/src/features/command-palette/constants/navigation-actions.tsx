import {
  FileTextIcon as FileText,
  FolderOpenIcon as FolderOpen,
  GitBranchIcon as GitBranch,
  HashIcon as Hash,
  ListBulletsIcon as ListBullets,
  MagnifyingGlassIcon as Search,
} from "@/ui/icons";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import type { SidebarView } from "@/features/layout/utils/sidebar-pane-utils";
import type { SettingsTab } from "@/features/window/stores/ui-state/types/ui-state.types";
import type { Action } from "../types/action.types";

interface NavigationActionsParams {
  setIsSidebarVisible: (v: boolean) => void;
  setActiveView: (view: SidebarView) => void;
  setIsQuickOpenVisible: (v: boolean) => void;
  openCommandPaletteView?: (view: "outline") => void;
  openSettingsDialog: (tab?: SettingsTab) => void;
  coreFeatures: { outline: boolean };
  onClose: () => void;
}

export const createNavigationActions = (params: NavigationActionsParams): Action[] => {
  const {
    setIsSidebarVisible,
    setActiveView,
    setIsQuickOpenVisible,
    openCommandPaletteView,
    coreFeatures,
    onClose,
  } = params;

  return [
    {
      id: "view-show-files",
      label: "View: Show Files",
      description: "Switch to files view",
      icon: <FolderOpen />,
      category: "Navigation",
      commandId: "workbench.showFileExplorer",
      action: () => {
        setIsSidebarVisible(true);
        setActiveView("files");
        onClose();
      },
    },
    {
      id: "view-show-git",
      label: "View: Show Git",
      description: "Switch to Git view",
      icon: <GitBranch />,
      category: "Navigation",
      commandId: "workbench.showSourceControl",
      action: () => {
        setIsSidebarVisible(true);
        setActiveView("git");
        onClose();
      },
    },
    ...(coreFeatures.outline
      ? [
          {
            id: "view-show-outline",
            label: "View: Show Outline",
            description: "Show symbols for the active file in the sidebar",
            icon: <ListBullets />,
            category: "Navigation",
            commandId: "workbench.showOutline",
            action: () => {
              setIsSidebarVisible(true);
              setActiveView("outline");
              onClose();
            },
          } satisfies Action,
        ]
      : []),
    {
      id: "search-global",
      label: "Search: Global Search",
      description: "Search across files in workspace",
      icon: <Search />,
      category: "Navigation",
      commandId: "workbench.showGlobalSearch",
      action: () => {
        onClose();
        useBufferStore.getState().actions.openGlobalSearchBuffer();
      },
    },
    {
      id: "go-to-line",
      label: "Go: Go to Line",
      description: "Jump to a specific line number",
      icon: <Hash />,
      category: "Navigation",
      commandId: "editor.goToLine",
      action: () => {
        onClose();
        window.dispatchEvent(new CustomEvent("menu-go-to-line"));
      },
    },
    {
      id: "quick-open",
      label: "Go: Quick Open",
      description: "Jump to any file with fuzzy search",
      icon: <FileText />,
      category: "Navigation",
      commandId: "file.quickOpen",
      action: () => {
        onClose();
        setIsQuickOpenVisible(true);
      },
    },
    {
      id: "go-to-symbol-in-editor",
      label: "Go: Symbol in Editor",
      description: "Open the active file outline picker",
      icon: <ListBullets />,
      category: "Navigation",
      commandId: "editor.showOutline",
      action: () => {
        onClose();
        openCommandPaletteView?.("outline");
      },
    },
  ];
};
