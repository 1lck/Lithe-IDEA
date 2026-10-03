import { getCurrentWindow, type Window as TauriWindow } from "@tauri-apps/api/window";
import { useCallback, useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { BACKEND_UNAVAILABLE_TOOLTIP } from "@/config/backend-capabilities";
import { useTranslation } from "@/i18n/locale-provider";
import { openFolder } from "@/features/file-system/controllers/platform";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { useFooterGitBranchItem } from "@/features/layout/components/footer/footer-git-branch-item";
import { COLLAPSED_ACTIVITY_RAIL_WIDTH } from "@/features/layout/constants/activity-rail";
import { AppUpdateControl } from "@/features/layout/components/app-update-control";
import SettingsDialog from "@/features/settings/components/settings-dialog";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { useWorkspaceTabsStore } from "@/features/window/stores/workspace-tabs.store";
import type { ProjectPickerMode } from "@/features/window/utils/project-picker-mode";
import { useNativeWindowChrome } from "@/features/window/hooks/use-native-window-chrome";
import { useProjectGradientColor } from "@/features/window/hooks/use-project-gradient";
import { useCompactMenuBarDismissal } from "@/features/window/hooks/use-compact-menu-bar-dismissal";
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
  GearIcon,
  ListIcon,
  MagnifyingGlassIcon,
  MenuIcon,
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

// IntelliJ main toolbar buttons: MainToolbar.Button.size 30x30, arc 12 (6px radius). Their icons
// set size-5 (iconSize 20) themselves: Button's unsized-svg rule outranks a parent [&_svg] override.
const MAIN_TOOLBAR_ICON_BUTTON_CLASS_NAME = "size-[30px] rounded-[6px]";

interface TitleBarProps {
  showMinimal?: boolean;
  showUpdateControl: boolean;
  onOpenProjectPicker: (mode?: ProjectPickerMode) => void;
}

export function TitleBarUpdateControl({ visible }: { visible: boolean }) {
  return visible ? <AppUpdateControl /> : null;
}

export const TitleBar = ({
  showMinimal = false,
  showUpdateControl,
  onOpenProjectPicker,
}: TitleBarProps) => {
  const { t } = useTranslation();
  const nativeMenuBar = useSettingsStore((state) => state.settings.nativeMenuBar);
  const compactMenuBar = useSettingsStore((state) => state.settings.compactMenuBar);
  const handleOpenFolder = useFileSystemStore((state) => state.handleOpenFolder);
  const closeProject = useFileSystemStore((state) => state.closeProject);
  const projectTabs = useWorkspaceTabsStore.use.projectTabs();
  useProjectGradientColor(projectTabs.find((tab) => tab.isActive)?.path);
  const setIsQuickOpenVisible = useUIState((state) => state.setIsQuickOpenVisible);
  const openSettingsDialog = useUIState((state) => state.openSettingsDialog);
  const branchItem = useFooterGitBranchItem();

  const [menuBarActiveMenu, setMenuBarActiveMenu] = useState<string | null>(null);
  const [isCompactMenuVisible, setIsCompactMenuVisible] = useState(false);
  const compactMenuBarContainerRef = useRef<HTMLDivElement>(null);
  const compactMenuToggleRef = useRef<HTMLButtonElement>(null);
  const [isMaximized, setIsMaximized] = useState(false);
  const [isFullscreen, setIsFullscreen] = useState(false);
  const [currentWindow, setCurrentWindow] = useState<TauriWindow | null>(null);

  const isMacOS = IS_MAC;
  const isWindows = IS_WINDOWS;
  const isLinux = IS_LINUX;
  const usesNativeWindowChrome = useNativeWindowChrome();
  const showAppWindowControls = !isMacOS && !usesNativeWindowChrome;
  const shouldUseNativeMenuBar = !isWindows && !isLinux && nativeMenuBar;
  const showCompactMenuBar = compactMenuBar && isCompactMenuVisible;

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
        // A window opened in the background starts inactive without a focus event.
        document.documentElement.toggleAttribute("data-window-inactive", !(await window.isFocused()));
        const unlistenResize = await window.onResized(() => {
          void syncWindowState();
        });
        const unlistenFocus = await window.onFocusChanged(({ payload: focused }) => {
          // Drives the IntelliJ Islands inactive-frame dimming in base.css.
          document.documentElement.toggleAttribute("data-window-inactive", !focused);
          void syncWindowState();
        });

        return () => {
          unlistenResize();
          unlistenFocus();
          document.documentElement.removeAttribute("data-window-inactive");
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

  const handleCompactMenuOpen = useCallback(() => {
    setMenuBarActiveMenu("File");
    setIsCompactMenuVisible(true);
  }, []);

  const handleCompactMenuClose = useCallback(() => {
    setMenuBarActiveMenu(null);
    setIsCompactMenuVisible(false);
  }, []);

  useCompactMenuBarDismissal(
    showCompactMenuBar,
    compactMenuBarContainerRef,
    handleCompactMenuClose,
    compactMenuToggleRef,
  );

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
        <div
          ref={compactMenuBarContainerRef}
          className={cn("flex min-w-0 items-center", showCompactMenuBar && "max-w-full")}
        >
          {showCompactMenuBar ? (
            <WindowMenuBar
              activeMenu={menuBarActiveMenu}
              setActiveMenu={setMenuBarActiveMenu}
              compactExpanded
              onCompactClose={handleCompactMenuClose}
            />
          ) : (
            <Tooltip content={t("window.menu")} side="bottom">
              <Button
                ref={compactMenuToggleRef}
                onClick={handleCompactMenuOpen}
                variant="ghost"
                size="icon-xs"
                className={MAIN_TOOLBAR_ICON_BUTTON_CLASS_NAME}
                aria-label={t("window.menu")}
                aria-expanded={false}
              >
                <MenuIcon large className="size-5" />
              </Button>
            </Tooltip>
          )}
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

  const appBrandMark = !isMacOS ? (
    <span
      aria-hidden="true"
      className="pointer-events-none flex h-full shrink-0 select-none items-center justify-center overflow-hidden rounded-md"
      style={{ width: COLLAPSED_ACTIVITY_RAIL_WIDTH }}
    >
      <img
        src="/logo.png"
        alt=""
        draggable={false}
        className="size-5 scale-[1.19] object-contain"
      />
    </span>
  ) : null;

  const quickOpenAction = (
    <Button
      type="button"
      variant="ghost"
      size="icon-xs"
      className={MAIN_TOOLBAR_ICON_BUTTON_CLASS_NAME}
      tooltip={t("workbench.search")}
      tooltipSide="bottom"
      onClick={() => setIsQuickOpenVisible(true)}
      aria-label={t("workbench.search")}
    >
      <MagnifyingGlassIcon large className="size-5" />
    </Button>
  );

  const settingsAction = (
    <Button
      type="button"
      variant="ghost"
      size="icon-xs"
      className={MAIN_TOOLBAR_ICON_BUTTON_CLASS_NAME}
      tooltip={t("workbench.settings")}
      tooltipSide="bottom"
      onClick={() => openSettingsDialog()}
      aria-label={t("workbench.settings")}
    >
      <GearIcon large className="size-5" />
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
        className={MAIN_TOOLBAR_ICON_BUTTON_CLASS_NAME}
        tooltip={t("workbench.moreProjectActions")}
        tooltipSide="bottom"
        onClick={() => onOpenProjectPicker()}
        aria-label={t("workbench.moreProjectActions")}
      >
        <ListIcon className="size-5" />
      </Button>
    </ChromeGroup>
  );

  if (showMinimal) {
    return (
      <ChromeBar
        region="title"
        onMouseDown={handleTitleBarMouseDown}
        className={cn(
          "lithe-title-bar relative z-50 justify-between select-none",
          isWindows && showAppWindowControls && "pr-0",
        )}
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
            {appBrandMark}
            {menuItem}
            {!showCompactMenuBar ? projectControls : null}
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
        className={cn(
          "lithe-title-bar font-sans ui-text-chrome relative z-50 flex h-(--lithe-title-bar-height) items-center justify-between gap-(--lithe-chrome-gap) bg-surface pr-(--lithe-chrome-padding-inline) pl-0 text-muted-foreground",
          isWindows && showAppWindowControls && "pr-0",
        )}
      >
        <ChromeGroup grow className="min-w-0">
          <ChromeGroup grow={showCompactMenuBar} className="pointer-events-auto min-w-0">
            {appBrandMark}
            {menuItem}
            {!showCompactMenuBar ? projectControls : null}
          </ChromeGroup>
        </ChromeGroup>
        <ChromeGroup className="pointer-events-auto z-20">
          {quickOpenAction}
          {settingsAction}
          {isWindows ? <TitleBarUpdateControl visible={showUpdateControl} /> : null}

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
  showUpdateControl,
}: Omit<TitleBarProps, "onOpenProjectPicker">) => {
  const isSettingsDialogVisible = useUIState((state) => state.isSettingsDialogVisible);
  const isProjectPickerVisible = useUIState((state) => state.isProjectPickerVisible);
  const setIsSettingsDialogVisible = useUIState((state) => state.setIsSettingsDialogVisible);
  const setIsProjectPickerVisible = useUIState((state) => state.setIsProjectPickerVisible);
  const projectPickerMode = useUIState((state) => state.projectPickerMode);
  const openProjectPicker = useCallback(
    (mode: ProjectPickerMode = "picker") => {
      setIsProjectPickerVisible(true, mode);
    },
    [setIsProjectPickerVisible],
  );
  const closeProjectPicker = useCallback(() => {
    setIsProjectPickerVisible(false);
  }, [setIsProjectPickerVisible]);

  return (
    <>
      <TitleBar
        showMinimal={showMinimal}
        showUpdateControl={showUpdateControl}
        onOpenProjectPicker={openProjectPicker}
      />
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
