import { getCurrentWindow, type Window as TauriWindow } from "@tauri-apps/api/window";
import { useCallback, useEffect, useState } from "react";
import { createPortal } from "react-dom";
import { BACKEND_UNAVAILABLE_TOOLTIP } from "@/config/backend-capabilities";
import { useTranslation } from "@/i18n/locale-provider";
import { openFolder } from "@/features/file-system/controllers/platform";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { useFooterGitBranchItem } from "@/features/layout/components/footer/footer-git-branch-item";
import { AppUpdateControl } from "@/features/layout/components/app-update-control";
import SettingsDialog from "@/features/settings/components/settings-dialog";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { useWorkspaceTabsStore } from "@/features/window/stores/workspace-tabs.store";
import type { ProjectPickerMode } from "@/features/window/utils/project-picker-mode";
import { useNativeWindowChrome } from "@/features/window/hooks/use-native-window-chrome";
import { createAppWindow } from "@/features/window/utils/create-app-window";
import { runTitleBarDrag } from "@/features/window/utils/title-bar-drag";
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
import { TitleProjectMenu } from "./title-project-menu";
import { WindowControls } from "./window-controls";
import WindowMenuBar from "../window-menu-bar";

interface TitleBarProps {
  showMinimal?: boolean;
  onOpenProjectPicker: (mode?: ProjectPickerMode) => void;
}

const TitleBar = ({ showMinimal = false, onOpenProjectPicker }: TitleBarProps) => {
  const { t } = useTranslation();
  const nativeMenuBar = useSettingsStore((state) => state.settings.nativeMenuBar);
  const compactMenuBar = useSettingsStore((state) => state.settings.compactMenuBar);
  const handleOpenFolder = useFileSystemStore((state) => state.handleOpenFolder);
  const closeProject = useFileSystemStore((state) => state.closeProject);
  const projectTabs = useWorkspaceTabsStore.use.projectTabs();
  const setIsQuickOpenVisible = useUIState((state) => state.setIsQuickOpenVisible);
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
    runTitleBarDrag(e, () => {
      void currentWindow?.startDragging().catch((error: unknown) => {
        console.error("Error starting window drag:", error);
      });
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
        {t("titleProject.newWindow")}
      </ContextMenuItem>
      <ContextMenuItem onClick={() => onOpenProjectPicker()}>
        <FilesIcon />
        {t("titleProject.addProject")}
      </ContextMenuItem>
      <ContextMenuItem onClick={() => void handleOpenFolder()}>
        <FolderOpenIcon />
        {t("titleProject.openFolder")}
      </ContextMenuItem>
      <ContextMenuItem onClick={() => void handleOpenFolderInNewWindow()}>
        <WindowExpandIcon />
        {t("titleProject.openFolderInNewWindow")}
      </ContextMenuItem>
      {projectTabs.length > 0 && (
        <>
          <ContextMenuSeparator />
          <ContextMenuItem onClick={() => void handleCloseAllProjects()}>
            <TrashIcon />
            {t("titleProject.closeAllProjects")}
          </ContextMenuItem>
        </>
      )}
    </ContextMenuContent>
  );

  const menuItem =
    !isMacOS && !shouldUseNativeMenuBar ? (
      compactMenuBar ? (
        <div className="relative">
          <Tooltip content={t("window.menu")} side="bottom">
            <Button
              onClick={handleCompactMenuToggle}
              variant="ghost"
              size="icon-xs"
              className={isCompactMenuVisible ? "bg-accent/70 text-foreground" : undefined}
              aria-label={t("window.menu")}
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

  const projectControls = (
    <ChromeGroup gap="tight" className="pointer-events-auto">
      <TitleProjectMenu onOpenProjectPicker={onOpenProjectPicker} />
      {branchItem?.content}
    </ChromeGroup>
  );

  const quickOpenAction = (
    <Button
      type="button"
      variant="ghost"
      size="icon-xs"
      tooltip={t("workbench.search")}
      tooltipSide="bottom"
      onClick={() => setIsQuickOpenVisible(true)}
      aria-label={t("workbench.search")}
    >
      <MagnifyingGlassIcon />
    </Button>
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
      {quickOpenAction}
      <Button
        type="button"
        variant="ghost"
        size="icon-xs"
        tooltip={t("workbench.moreProjectActions")}
        tooltipSide="bottom"
        onClick={() => onOpenProjectPicker()}
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
          onMouseDown={handleTitleBarMouseDown}
        >
          <ChromeGroup className="pointer-events-auto h-full">
            {menuItem}
            {projectControls}
          </ChromeGroup>

          <ChromeGroup className="h-full">
            {workbenchActions}
          </ChromeGroup>
        </ContextMenuTrigger>
        {titleBarContextMenuContent}
      </ContextMenu>
    );
  }

  return (
    <ContextMenu>
      <ContextMenuTrigger
        onMouseDown={handleTitleBarMouseDown}
        onContextMenu={handleTitleBarContextMenu}
        className="lithe-title-bar font-sans ui-text-chrome relative z-50 flex h-(--lithe-title-bar-height) items-center justify-between gap-(--lithe-chrome-gap) bg-surface px-(--lithe-chrome-padding-inline) text-muted-foreground"
      >
        <ChromeGroup grow className="min-w-0">
          <ChromeGroup className="pointer-events-auto min-w-0">
            {menuItem}
            {projectControls}
          </ChromeGroup>
        </ChromeGroup>
        <ChromeGroup className="pointer-events-auto z-20">
          {quickOpenAction}
          {isWindows ? <AppUpdateControl /> : null}

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

const TitleBarWithSettings = ({
  showMinimal = false,
}: Omit<TitleBarProps, "onOpenProjectPicker">) => {
  const isSettingsDialogVisible = useUIState((state) => state.isSettingsDialogVisible);
  const isProjectPickerVisible = useUIState((state) => state.isProjectPickerVisible);
  const setIsSettingsDialogVisible = useUIState((state) => state.setIsSettingsDialogVisible);
  const setIsProjectPickerVisible = useUIState((state) => state.setIsProjectPickerVisible);
  const [projectPickerMode, setProjectPickerMode] = useState<ProjectPickerMode>("picker");
  const openProjectPicker = useCallback(
    (mode: ProjectPickerMode = "picker") => {
      setProjectPickerMode(mode);
      setIsProjectPickerVisible(true);
    },
    [setIsProjectPickerVisible],
  );
  const closeProjectPicker = useCallback(() => {
    setProjectPickerMode("picker");
    setIsProjectPickerVisible(false);
  }, [setIsProjectPickerVisible]);

  return (
    <>
      <TitleBar showMinimal={showMinimal} onOpenProjectPicker={openProjectPicker} />
      <SettingsDialog
        isOpen={isSettingsDialogVisible}
        onClose={() => setIsSettingsDialogVisible(false)}
      />
      {createPortal(
        <ProjectPicker
          initialMode={projectPickerMode}
          isOpen={isProjectPickerVisible}
          onClose={closeProjectPicker}
        />,
        document.body,
      )}
    </>
  );
};

export default TitleBarWithSettings;
