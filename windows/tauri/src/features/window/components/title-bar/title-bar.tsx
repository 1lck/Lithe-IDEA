import { getCurrentWindow, type Window as TauriWindow } from "@tauri-apps/api/window";
import { useCallback, useEffect, useState } from "react";
import { createPortal } from "react-dom";
import { BACKEND_UNAVAILABLE_TOOLTIP } from "@/config/backend-capabilities";
import { useTranslation } from "@/i18n/locale-provider";
import { openFolder } from "@/features/file-system/controllers/platform";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import type { HeaderTrailingItemId } from "@/features/layout/config/item-order";
import { orderChromeItems, type ChromeItem } from "@/features/layout/utils/chrome-items";
import { useFooterGitBranchItem } from "@/features/layout/components/footer/footer-git-branch-item";
import SettingsDialog from "@/features/settings/components/settings-dialog";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { useWorkspaceTabsStore } from "@/features/window/stores/workspace-tabs.store";
import { useNativeWindowChrome } from "@/features/window/hooks/use-native-window-chrome";
import { createAppWindow } from "@/features/window/utils/create-app-window";
import { Button } from "@/ui/button";
import { ChromeBar, ChromeGroup } from "@/ui/chrome";
import {
  ContextMenu,
  ContextMenuContent,
  ContextMenuItem,
  ContextMenuSeparator,
  ContextMenuTrigger,
} from "@/ui/context-menu";
import {
  FilesIcon,
  FolderOpenIcon,
  ListIcon,
  MagnifyingGlassIcon,
  PlayIcon,
  TrashIcon,
  WindowExpandIcon,
} from "@/ui/icons";
import Tooltip from "@/ui/tooltip";
import { cn } from "@/utils/cn";
import { IS_LINUX, IS_MAC, IS_WINDOWS } from "@/utils/platform";
import ProjectPicker from "../project-picker";
import { WindowControls } from "./window-controls";
import WindowMenuBar from "../window-menu-bar";

interface TitleBarProps {
  showMinimal?: boolean;
}

function TitleBarTrailingActions({ items }: { items: Array<ChromeItem<HeaderTrailingItemId>> }) {
  return (
    <ChromeGroup gap="tight">
      {items.map((item) =>
        item.content ? (
          <div key={item.id} className="flex min-h-(--lithe-chrome-control-height) items-center">
            {item.content}
          </div>
        ) : null,
      )}
    </ChromeGroup>
  );
}

const TitleBar = ({ showMinimal = false }: TitleBarProps) => {
  const { t } = useTranslation();
  const nativeMenuBar = useSettingsStore((state) => state.settings.nativeMenuBar);
  const compactMenuBar = useSettingsStore((state) => state.settings.compactMenuBar);
  const headerTrailingItemsOrder = useSettingsStore(
    (state) => state.settings.headerTrailingItemsOrder,
  );
  const handleOpenFolder = useFileSystemStore((state) => state.handleOpenFolder);
  const closeProject = useFileSystemStore((state) => state.closeProject);
  const projectTabs = useWorkspaceTabsStore.use.projectTabs();
  const setIsProjectPickerVisible = useUIState((state) => state.setIsProjectPickerVisible);
  const setIsGlobalSearchVisible = useUIState((state) => state.setIsGlobalSearchVisible);
  const branchItem = useFooterGitBranchItem();

  const [menuBarActiveMenu, setMenuBarActiveMenu] = useState<string | null>(null);
  const [isCompactMenuVisible, setIsCompactMenuVisible] = useState(false);
  const [isMaximized, setIsMaximized] = useState(false);
  const [isFullscreen, setIsFullscreen] = useState(false);
  const [currentWindow, setCurrentWindow] = useState<TauriWindow | null>(null);

  const isMacOS = IS_MAC;
  const isWindows = IS_WINDOWS;
  const isLinux = IS_LINUX;
  const usesNativeWindowChrome = useNativeWindowChrome();
  const showAppWindowControls = !isMacOS && !usesNativeWindowChrome;
  const shouldUseNativeMenuBar = !isWindows && !isLinux && nativeMenuBar;

  useEffect(() => {
    const initWindow = async () => {
      const window = getCurrentWindow();
      setCurrentWindow(window);

      const syncWindowState = async () => {
        try {
          const [maximized, fullscreen] = await Promise.all([
            window.isMaximized(),
            window.isFullscreen(),
          ]);
          setIsMaximized(maximized);
          setIsFullscreen(fullscreen);
        } catch (error) {
          console.error("Error checking window state:", error);
        }
      };

      try {
        await syncWindowState();
        const unlistenResize = await window.onResized(() => {
          void syncWindowState();
        });
        const unlistenFocus = await window.onFocusChanged(() => {
          void syncWindowState();
        });

        return () => {
          unlistenResize();
          unlistenFocus();
        };
      } catch (error) {
        console.error("Error subscribing to window state:", error);
      }
    };

    let cleanup: (() => void) | void;
    void initWindow().then((dispose) => {
      cleanup = dispose;
    });

    return () => {
      cleanup?.();
    };
  }, []);

  const handleTitleBarContextMenu = (e: React.MouseEvent<HTMLDivElement>) => {
    const target = e.target as HTMLElement;
    const interactiveTarget = target.closest(
      "button, a, input, textarea, select, [role='tab'], [contenteditable='true']",
    );

    if (interactiveTarget) {
      e.preventDefault();
      return;
    }
  };

  const handleTitleBarMouseDown = (e: React.MouseEvent<HTMLDivElement>) => {
    if (e.button !== 0) return;

    const target = e.target as HTMLElement;
    const interactiveTarget = target.closest(
      "button, a, input, textarea, select, [role='tab'], [contenteditable='true']",
    );

    if (interactiveTarget) return;

    void currentWindow?.startDragging().catch((error: unknown) => {
      console.error("Error starting window drag:", error);
    });
  };

  const handleOpenFolderInNewWindow = async () => {
    const selected = await openFolder();
    if (!selected) return;

    await createAppWindow({
      path: selected,
      isDirectory: true,
    });
  };

  const handleCloseAllProjects = useCallback(async () => {
    const tabsToClose = [...useWorkspaceTabsStore.getState().projectTabs];

    for (const tab of tabsToClose) {
      await closeProject(tab.id);
    }
  }, [closeProject]);

  const handleCompactMenuToggle = useCallback(() => {
    setMenuBarActiveMenu(null);
    setIsCompactMenuVisible((visible) => !visible);
  }, []);

  const handleCompactMenuClose = useCallback(() => {
    setMenuBarActiveMenu(null);
    setIsCompactMenuVisible(false);
  }, []);

  const titleBarContextMenuContent = (
    <ContextMenuContent>
      <ContextMenuItem onClick={() => void createAppWindow()}>
        <WindowExpandIcon />
        New Window
      </ContextMenuItem>
      <ContextMenuItem onClick={() => setIsProjectPickerVisible(true)}>
        <FilesIcon />
        Add Project
      </ContextMenuItem>
      <ContextMenuItem onClick={() => void handleOpenFolder()}>
        <FolderOpenIcon />
        Open Folder
      </ContextMenuItem>
      <ContextMenuItem onClick={() => void handleOpenFolderInNewWindow()}>
        <WindowExpandIcon />
        Open Folder in New Window
      </ContextMenuItem>
      {projectTabs.length > 0 && (
        <>
          <ContextMenuSeparator />
          <ContextMenuItem onClick={() => void handleCloseAllProjects()}>
            <TrashIcon />
            Close All Projects
          </ContextMenuItem>
        </>
      )}
    </ContextMenuContent>
  );

  const menuItem =
    !isMacOS && !shouldUseNativeMenuBar ? (
      compactMenuBar ? (
        <div className="relative">
          <Tooltip content="Menu" side="bottom">
            <Button
              onClick={handleCompactMenuToggle}
              variant="ghost"
              size="icon-xs"
              className={isCompactMenuVisible ? "bg-accent/70 text-foreground" : undefined}
              aria-label="Menu"
              aria-expanded={isCompactMenuVisible}
            >
              <ListIcon />
            </Button>
          </Tooltip>
          {isCompactMenuVisible ? (
            <WindowMenuBar
              activeMenu={menuBarActiveMenu}
              setActiveMenu={setMenuBarActiveMenu}
              compactFloating
              onCompactClose={handleCompactMenuClose}
            />
          ) : null}
        </div>
      ) : (
        <WindowMenuBar activeMenu={menuBarActiveMenu} setActiveMenu={setMenuBarActiveMenu} />
      )
    ) : null;

  const headerTrailingItems: Array<ChromeItem<HeaderTrailingItemId>> = [];
  const orderedTrailingItems = orderChromeItems(headerTrailingItems, headerTrailingItemsOrder);

  const activeProject = projectTabs.find((project) => project.isActive);
  const projectLabel = activeProject?.name ?? t("workbench.openProject");
  const macOSAlignedControls = (
    <ChromeGroup gap="tight" className="pointer-events-auto">
      <Button
        type="button"
        variant="ghost"
        size="xs"
        className="max-w-56 justify-start gap-2 px-2"
        onClick={() => setIsProjectPickerVisible(true)}
      >
        <img src="/logo.png" alt="" className="size-5 rounded-md" />
        <span className="truncate">{projectLabel}</span>
      </Button>
      {branchItem?.content}
    </ChromeGroup>
  );

  const workbenchActions = (
    <ChromeGroup gap="tight" className="pointer-events-auto">
      <Tooltip content={BACKEND_UNAVAILABLE_TOOLTIP} side="bottom">
        <span>
          <Button
            type="button"
            variant="ghost"
            size="xs"
            className="min-w-44 justify-start gap-2 px-2"
            disabled
          >
            <PlayIcon />
            <span className="truncate">{t("workbench.currentFile")}</span>
          </Button>
        </span>
      </Tooltip>
      <Button
        type="button"
        variant="ghost"
        size="icon-xs"
        tooltip={t("workbench.search")}
        tooltipSide="bottom"
        onClick={() => setIsGlobalSearchVisible(true)}
        aria-label={t("workbench.search")}
      >
        <MagnifyingGlassIcon />
      </Button>
      <Button
        type="button"
        variant="ghost"
        size="icon-xs"
        tooltip={t("workbench.moreProjectActions")}
        tooltipSide="bottom"
        onClick={() => setIsProjectPickerVisible(true)}
        aria-label={t("workbench.moreProjectActions")}
      >
        <ListIcon />
      </Button>
    </ChromeGroup>
  );

  if (showMinimal) {
    return (
      <ChromeBar
        region="title"
        data-tauri-drag-region
        onMouseDown={handleTitleBarMouseDown}
        className="lithe-title-bar relative z-50 justify-between select-none"
      >
        <ChromeGroup grow />

        {showAppWindowControls && (
          <WindowControls
            currentWindow={currentWindow}
            isMaximized={isMaximized}
            onMaximizedChange={setIsMaximized}
          />
        )}
      </ChromeBar>
    );
  }

  if (isMacOS) {
    return (
      <ContextMenu>
        <ContextMenuTrigger
          onContextMenu={handleTitleBarContextMenu}
          className={cn(
            "lithe-title-bar font-sans ui-text-chrome relative z-50 flex h-(--lithe-title-bar-height) items-center justify-between gap-(--lithe-chrome-gap) bg-transparent pr-(--lithe-chrome-padding-inline) text-subtle-foreground",
            isFullscreen ? "pl-2" : "pl-23.5",
          )}
          data-tauri-drag-region
          onMouseDown={handleTitleBarMouseDown}
        >
          <ChromeGroup className="pointer-events-auto h-full">
            {menuItem}
            {macOSAlignedControls}
          </ChromeGroup>

          <ChromeGroup className="h-full">
            {workbenchActions}
            <TitleBarTrailingActions items={orderedTrailingItems} />
          </ChromeGroup>
        </ContextMenuTrigger>
        {titleBarContextMenuContent}
      </ContextMenu>
    );
  }

  return (
    <ContextMenu>
      <ContextMenuTrigger
        data-tauri-drag-region
        onMouseDown={handleTitleBarMouseDown}
        onContextMenu={handleTitleBarContextMenu}
        className="lithe-title-bar font-sans ui-text-chrome relative z-50 flex h-(--lithe-title-bar-height) items-center justify-between gap-(--lithe-chrome-gap) bg-transparent px-(--lithe-chrome-padding-inline) text-subtle-foreground"
      >
        <ChromeGroup data-tauri-drag-region grow>
          <ChromeGroup className="pointer-events-auto">{macOSAlignedControls}</ChromeGroup>
        </ChromeGroup>
        <ChromeGroup className="z-20">
          <TitleBarTrailingActions items={orderedTrailingItems} />

          {showAppWindowControls && (
            <WindowControls
              currentWindow={currentWindow}
              isMaximized={isMaximized}
              onMaximizedChange={setIsMaximized}
            />
          )}
        </ChromeGroup>
      </ContextMenuTrigger>
      {titleBarContextMenuContent}
    </ContextMenu>
  );
};

const TitleBarWithSettings = (props: TitleBarProps) => {
  const isSettingsDialogVisible = useUIState((state) => state.isSettingsDialogVisible);
  const isProjectPickerVisible = useUIState((state) => state.isProjectPickerVisible);
  const setIsSettingsDialogVisible = useUIState((state) => state.setIsSettingsDialogVisible);
  const setIsProjectPickerVisible = useUIState((state) => state.setIsProjectPickerVisible);

  return (
    <>
      <TitleBar {...props} />
      <SettingsDialog
        isOpen={isSettingsDialogVisible}
        onClose={() => setIsSettingsDialogVisible(false)}
      />
      {createPortal(
        <ProjectPicker
          isOpen={isProjectPickerVisible}
          onClose={() => setIsProjectPickerVisible(false)}
        />,
        document.body,
      )}
    </>
  );
};

export default TitleBarWithSettings;
