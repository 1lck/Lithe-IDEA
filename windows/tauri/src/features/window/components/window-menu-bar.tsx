import { invoke } from "@/platform/tauri-core";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { getCurrentWebviewWindow } from "@tauri-apps/api/webviewWindow";
import { exit } from "@tauri-apps/plugin-process";
import type React from "react";
import { useCallback, useEffect, useMemo, useRef } from "react";
import {
  BACKEND_UNAVAILABLE_TOOLTIP,
  isBackendCapabilityAvailable,
} from "@/config/backend-capabilities";
import { useRegisteredThemes } from "@/extensions/themes/use-registered-themes";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { useTranslation } from "@/i18n/locale-provider";
import { createAppWindow } from "@/features/window/utils/create-app-window";
import {
  Menubar,
  MenubarContent,
  MenubarItem,
  MenubarMenu,
  MenubarSeparator,
  MenubarSub,
  MenubarSubContent,
  MenubarSubTrigger,
  MenubarTrigger,
} from "@/ui/menubar";
import { cn } from "@/utils/cn";
import { IS_LINUX, IS_WINDOWS } from "@/utils/platform";

interface Props {
  activeMenu: string | null;
  setActiveMenu: React.Dispatch<React.SetStateAction<string | null>>;
  compactFloating?: boolean;
  onCompactClose?: () => void;
}

const WindowMenuBar = ({
  activeMenu,
  setActiveMenu,
  compactFloating = false,
  onCompactClose,
}: Props) => {
  const { t } = useTranslation();
  const compactMenuBar = useSettingsStore((state) => state.settings.compactMenuBar);
  const themes = useRegisteredThemes();
  const menuWindowRaiseRef = useRef<{ restoreTo: boolean } | null>(null);
  const shouldRaiseWindowForMenu = (IS_WINDOWS || IS_LINUX) && Boolean(activeMenu);
  const closeMenu = useCallback(() => {
    setActiveMenu(null);
    onCompactClose?.();
  }, [onCompactClose, setActiveMenu]);

  useEffect(() => {
    let disposed = false;
    const window = getCurrentWindow();

    const restoreWindowLevel = async () => {
      const previous = menuWindowRaiseRef.current;
      if (!previous) return;

      menuWindowRaiseRef.current = null;

      try {
        await window.setAlwaysOnTop(previous.restoreTo);
      } catch (error) {
        console.error("Failed to restore window menu level:", error);
      }
    };

    if (!shouldRaiseWindowForMenu) {
      void restoreWindowLevel();
      return;
    }

    if (menuWindowRaiseRef.current) {
      return;
    }

    void (async () => {
      try {
        const wasAlwaysOnTop = await window.isAlwaysOnTop();

        if (!wasAlwaysOnTop) {
          await window.setAlwaysOnTop(true);
        }

        if (disposed) {
          if (!wasAlwaysOnTop) {
            await window.setAlwaysOnTop(false);
          }
          return;
        }

        menuWindowRaiseRef.current = { restoreTo: wasAlwaysOnTop };
      } catch (error) {
        console.error("Failed to raise window menu level:", error);
      }
    })();

    return () => {
      disposed = true;
      void restoreWindowLevel();
    };
  }, [shouldRaiseWindowForMenu]);

  const handleClickEmit = useCallback(
    (event: string, payload?: unknown) => {
      const currentWindow = getCurrentWebviewWindow();
      void currentWindow.emitTo(currentWindow.label, event, payload);
      closeMenu();
    },
    [closeMenu],
  );

  const handleOpenWebInspector = useCallback(() => {
    void invoke("reopen_current_webview_devtools");
    closeMenu();
  }, [closeMenu]);

  const handleCommand = useCallback(
    (commandId: string) => {
      handleClickEmit("menu_execute_command", commandId);
    },
    [handleClickEmit],
  );

  const handleNewWindow = useCallback(() => {
    void createAppWindow();
    closeMenu();
  }, [closeMenu]);

  const menus = useMemo(
    () => ({
      File: (
        <MenubarContent>
          <MenubarItem shortcut="mod+n" onClick={() => handleCommand("workbench.newTab")}>
            {t("menu.newTab")}
          </MenubarItem>
          <MenubarItem shortcut="mod+shift+n" onClick={handleNewWindow}>
            {t("menu.newWindow")}
          </MenubarItem>
          <MenubarItem onClick={() => handleClickEmit("menu_new_file")}>
            {t("menu.newFile")}
          </MenubarItem>
          <MenubarItem shortcut="mod+o" onClick={() => handleClickEmit("menu_open_folder")}>
            {t("menu.openFolder")}
          </MenubarItem>
          <MenubarItem onClick={() => handleClickEmit("menu_close_folder")}>
            {t("menu.closeFolder")}
          </MenubarItem>
          <MenubarSeparator />
          <MenubarItem shortcut="mod+s" onClick={() => handleClickEmit("menu_save")}>
            {t("menu.save")}
          </MenubarItem>
          <MenubarItem shortcut="mod+shift+s" onClick={() => handleClickEmit("menu_save_as")}>
            {t("menu.saveAs")}
          </MenubarItem>
          <MenubarItem shortcut="mod+alt+s" onClick={() => handleCommand("file.saveAll")}>
            {t("menu.saveAll")}
          </MenubarItem>
          <MenubarItem onClick={() => handleCommand("file.revert")}>
            {t("menu.revertFile")}
          </MenubarItem>
          <MenubarItem onClick={() => handleCommand("file.localHistory")}>
            {t("menu.showLocalHistory")}
          </MenubarItem>
          <MenubarSeparator />
          <MenubarItem shortcut="mod+w" onClick={() => handleClickEmit("menu_close_tab")}>
            {t("menu.closeTab")}
          </MenubarItem>
          <MenubarItem
            shortcut="mod+shift+w"
            onClick={() => handleCommand("workbench.closeWindow")}
          >
            {t("menu.closeWindow")}
          </MenubarItem>
          <MenubarItem onClick={() => handleCommand("file.closeAll")}>
            {t("menu.closeAllTabs")}
          </MenubarItem>
          <MenubarItem onClick={() => handleCommand("file.closeOthers")}>
            {t("menu.closeOtherTabs")}
          </MenubarItem>
          <MenubarItem onClick={() => handleCommand("file.closeSaved")}>
            {t("menu.closeSavedTabs")}
          </MenubarItem>
          <MenubarItem onClick={() => handleCommand("file.closeTabsToLeft")}>
            {t("menu.closeTabsToLeft")}
          </MenubarItem>
          <MenubarItem onClick={() => handleCommand("file.closeTabsToRight")}>
            {t("menu.closeTabsToRight")}
          </MenubarItem>
          <MenubarItem shortcut="mod+shift+t" onClick={() => handleCommand("file.reopenClosed")}>
            {t("menu.reopenClosedTab")}
          </MenubarItem>
          <MenubarSeparator />
          <MenubarItem shortcut="mod+q" onClick={async () => await exit(0)}>
            {t("menu.quit")}
          </MenubarItem>
        </MenubarContent>
      ),
      Edit: (
        <MenubarContent>
          <MenubarItem shortcut="mod+z" onClick={() => handleClickEmit("menu_undo")}>
            {t("menu.undo")}
          </MenubarItem>
          <MenubarItem shortcut="mod+shift+z" onClick={() => handleClickEmit("menu_redo")}>
            {t("menu.redo")}
          </MenubarItem>
          <MenubarSeparator />
          <MenubarItem shortcut="mod+x" onClick={() => handleCommand("editor.cut")}>
            {t("menu.cut")}
          </MenubarItem>
          <MenubarItem shortcut="mod+c" onClick={() => handleCommand("editor.copy")}>
            {t("menu.copy")}
          </MenubarItem>
          <MenubarItem shortcut="mod+v" onClick={() => handleCommand("editor.paste")}>
            {t("menu.paste")}
          </MenubarItem>
          <MenubarItem shortcut="mod+a" onClick={() => handleCommand("editor.selectAll")}>
            {t("menu.selectAll")}
          </MenubarItem>
          <MenubarSeparator />
          <MenubarItem shortcut="mod+f" onClick={() => handleClickEmit("menu_find")}>
            {t("menu.find")}
          </MenubarItem>
          <MenubarItem shortcut="mod+alt+f" onClick={() => handleClickEmit("menu_find_replace")}>
            {t("menu.findAndReplace")}
          </MenubarItem>
          <MenubarItem shortcut="mod+/" onClick={() => handleClickEmit("menu_toggle_comment")}>
            {t("menu.toggleComment")}
          </MenubarItem>
          <MenubarItem shortcut="mod+." onClick={() => handleCommand("editor.quickFix")}>
            {t("menu.quickFix")}
          </MenubarItem>
          <MenubarItem
            shortcut="mod+shift+space"
            onClick={() => handleCommand("editor.triggerParameterHints")}
          >
            {t("menu.triggerParameterHints")}
          </MenubarItem>
          <MenubarItem shortcut="mod+k mod+i" onClick={() => handleCommand("editor.showHover")}>
            {t("menu.showHover")}
          </MenubarItem>
          <MenubarSeparator />
          <MenubarItem shortcut="mod+d" onClick={() => handleCommand("editor.duplicateLine")}>
            {t("menu.duplicateLine")}
          </MenubarItem>
          <MenubarItem shortcut="mod+shift+k" onClick={() => handleCommand("editor.deleteLine")}>
            {t("menu.deleteLine")}
          </MenubarItem>
          <MenubarItem shortcut="alt+up" onClick={() => handleCommand("editor.moveLineUp")}>
            {t("menu.moveLineUp")}
          </MenubarItem>
          <MenubarItem shortcut="alt+down" onClick={() => handleCommand("editor.moveLineDown")}>
            {t("menu.moveLineDown")}
          </MenubarItem>
          <MenubarItem
            shortcut="shift+alt+f"
            onClick={() => handleCommand("editor.formatDocument")}
          >
            {t("menu.formatDocument")}
          </MenubarItem>
          <MenubarItem
            shortcut="mod+k mod+f"
            onClick={() => handleCommand("editor.formatSelection")}
          >
            {t("menu.formatSelection")}
          </MenubarItem>
          <MenubarSeparator />
          <MenubarItem
            shortcut="mod+shift+p"
            onClick={() => handleClickEmit("menu_command_palette")}
          >
            {t("menu.commandPalette")}
          </MenubarItem>
        </MenubarContent>
      ),
      View: (
        <MenubarContent>
          <MenubarItem
            shortcut="mod+b"
            onClick={() => handleClickEmit("menu_toggle_activity_sidebar")}
          >
            {t("menu.toggleActivitySidebar")}
          </MenubarItem>
          <MenubarItem shortcut="mod+e" onClick={() => handleClickEmit("menu_toggle_sidebar")}>
            {t("menu.toggleSecondarySidebar")}
          </MenubarItem>
          <MenubarItem shortcut="mod+j" onClick={() => handleClickEmit("menu_toggle_terminal")}>
            {t("menu.toggleTerminal")}
          </MenubarItem>
          <MenubarSeparator />
          <MenubarItem
            shortcut="mod+shift+f"
            onClick={() => handleCommand("workbench.showGlobalSearch")}
          >
            {t("menu.globalSearch")}
          </MenubarItem>
          <MenubarItem
            shortcut="mod+shift+j"
            onClick={() => handleCommand("workbench.toggleDiagnostics")}
          >
            {t("menu.diagnostics")}
          </MenubarItem>
          <MenubarSeparator />
          <MenubarItem
            shortcut="mod+shift+e"
            onClick={() => handleCommand("workbench.showFileExplorer")}
          >
            {t("menu.fileExplorer")}
          </MenubarItem>
          <MenubarItem
            shortcut="mod+shift+g"
            onClick={() => handleCommand("workbench.showSourceControl")}
          >
            {t("menu.sourceControl")}
          </MenubarItem>
          <MenubarItem onClick={() => handleCommand("workbench.showGitHub")}>
            {t("menu.github")}
          </MenubarItem>
          <MenubarItem onClick={() => handleCommand("workbench.showDebugger")}>
            {t("menu.runAndDebug")}
          </MenubarItem>
          <MenubarSeparator />
          <MenubarItem onClick={() => handleClickEmit("menu_split_editor")}>
            {t("menu.splitEditor")}
          </MenubarItem>
          <MenubarItem onClick={() => handleCommand("workbench.toggleMinimap")}>
            {t("menu.toggleMinimap")}
          </MenubarItem>
          <MenubarItem shortcut="alt+z" onClick={() => handleCommand("editor.toggleWordWrap")}>
            {t("menu.toggleWordWrap")}
          </MenubarItem>
          <MenubarItem onClick={() => handleCommand("editor.toggleLineNumbers")}>
            {t("menu.toggleLineNumbers")}
          </MenubarItem>
          <MenubarItem onClick={() => handleCommand("editor.toggleRenderWhitespace")}>
            {t("menu.toggleRenderWhitespace")}
          </MenubarItem>
          <MenubarSeparator />
          <MenubarItem shortcut="mod+=" onClick={() => handleCommand("workbench.zoomIn")}>
            {t("menu.zoomIn")}
          </MenubarItem>
          <MenubarItem shortcut="mod+-" onClick={() => handleCommand("workbench.zoomOut")}>
            {t("menu.zoomOut")}
          </MenubarItem>
          <MenubarItem shortcut="mod+0" onClick={() => handleCommand("workbench.zoomReset")}>
            {t("menu.resetZoom")}
          </MenubarItem>
          <MenubarSeparator />
          <MenubarSub>
            <MenubarSubTrigger>{t("menu.theme")}</MenubarSubTrigger>
            <MenubarSubContent>
              {themes.map((theme) => (
                <MenubarItem
                  key={theme.id}
                  onClick={() => handleClickEmit("menu_theme_change", theme.id)}
                >
                  {theme.name}
                </MenubarItem>
              ))}
            </MenubarSubContent>
          </MenubarSub>
        </MenubarContent>
      ),
      Go: (
        <MenubarContent>
          <MenubarItem shortcut="mod+p" onClick={() => handleClickEmit("menu_quick_open")}>
            {t("menu.quickOpen")}
          </MenubarItem>
          <MenubarItem shortcut="mod+g" onClick={() => handleClickEmit("menu_go_to_line")}>
            {t("menu.goToLine")}
          </MenubarItem>
          <MenubarSeparator />
          <MenubarItem shortcut="ctrl+-" onClick={() => handleCommand("navigation.goBack")}>
            {t("menu.goBack")}
          </MenubarItem>
          <MenubarItem
            shortcut="ctrl+shift+-"
            onClick={() => handleCommand("navigation.goForward")}
          >
            {t("menu.goForward")}
          </MenubarItem>
          <MenubarSeparator />
          <MenubarItem shortcut="f12" onClick={() => handleCommand("editor.goToDefinition")}>
            {t("menu.goToDefinition")}
          </MenubarItem>
          <MenubarItem
            shortcut="mod+f12"
            onClick={() => handleCommand("editor.goToImplementation")}
          >
            {t("menu.goToImplementation")}
          </MenubarItem>
          <MenubarItem onClick={() => handleCommand("editor.goToTypeDefinition")}>
            {t("menu.goToTypeDefinition")}
          </MenubarItem>
          <MenubarItem shortcut="mod+b" onClick={() => handleCommand("editor.goToReferences")}>
            {t("menu.goToReferences")}
          </MenubarItem>
          <MenubarItem shortcut="f2" onClick={() => handleCommand("editor.renameSymbol")}>
            {t("menu.renameSymbol")}
          </MenubarItem>
          <MenubarSeparator />
          <MenubarItem shortcut="mod+alt+right" onClick={() => handleClickEmit("menu_next_tab")}>
            {t("menu.nextTab")}
          </MenubarItem>
          <MenubarItem shortcut="mod+alt+left" onClick={() => handleClickEmit("menu_prev_tab")}>
            {t("menu.previousTab")}
          </MenubarItem>
        </MenubarContent>
      ),
      Terminal: (
        <MenubarContent>
          <MenubarItem onClick={() => handleCommand("terminal.new")}>
            {t("menu.newTerminal")}
          </MenubarItem>
          <MenubarItem shortcut="mod+d" onClick={() => handleCommand("terminal.split")}>
            {t("menu.splitTerminalRight")}
          </MenubarItem>
          <MenubarItem shortcut="mod+shift+d" onClick={() => handleCommand("terminal.splitDown")}>
            {t("menu.splitTerminalDown")}
          </MenubarItem>
          <MenubarItem onClick={() => handleCommand("terminal.close")}>
            {t("menu.closeTerminal")}
          </MenubarItem>
        </MenubarContent>
      ),
      Run: (
        <MenubarContent>
          <MenubarItem shortcut="f5" onClick={() => handleCommand("debug.start")}>
            {t("menu.startDebugging")}
          </MenubarItem>
          <MenubarItem shortcut="shift+f5" onClick={() => handleCommand("debug.stop")}>
            {t("menu.stopDebugging")}
          </MenubarItem>
          <MenubarItem shortcut="f9" onClick={() => handleCommand("debug.toggleBreakpoint")}>
            {t("menu.toggleBreakpoint")}
          </MenubarItem>
        </MenubarContent>
      ),
      Tools: (
        <MenubarContent>
          <MenubarItem
            onClick={() => handleCommand("database.connect")}
            disabled={!isBackendCapabilityAvailable("database")}
            title={BACKEND_UNAVAILABLE_TOOLTIP}
          >
            {t("menu.databases")}
          </MenubarItem>
          <MenubarSeparator />
          <MenubarItem shortcut="mod+alt+i" onClick={handleOpenWebInspector}>
            {t("menu.webInspector")}
          </MenubarItem>
          <MenubarSeparator />
          <MenubarItem onClick={() => handleClickEmit("menu_open_settings")}>
            {t("menu.preferences")}
          </MenubarItem>
          <MenubarItem onClick={() => handleCommand("workbench.openKeyboardShortcuts")}>
            {t("menu.keyboardShortcuts")}
          </MenubarItem>
        </MenubarContent>
      ),
      Window: (
        <MenubarContent>
          <MenubarItem
            shortcut="alt+f9"
            onClick={async () => {
              await getCurrentWindow().minimize();
              closeMenu();
            }}
          >
            {t("menu.minimize")}
          </MenubarItem>
          <MenubarItem
            shortcut="alt+f10"
            onClick={async () => {
              await getCurrentWindow().maximize();
              closeMenu();
            }}
          >
            {t("menu.maximize")}
          </MenubarItem>
          {!IS_LINUX && (
            <>
              <MenubarSeparator />
              <MenubarItem shortcut="alt+m" onClick={() => handleClickEmit("menu_toggle_menu_bar")}>
                {t("menu.toggleMenuBar")}
              </MenubarItem>
              <MenubarSeparator />
            </>
          )}
          <MenubarItem
            shortcut="f11"
            onClick={async () => {
              const window = getCurrentWindow();
              const isFull = await window.isFullscreen();
              await window.setFullscreen(!isFull);
              closeMenu();
            }}
          >
            {t("menu.toggleFullscreen")}
          </MenubarItem>
        </MenubarContent>
      ),
      Help: (
        <MenubarContent>
          <MenubarItem onClick={() => handleClickEmit("menu_documentation")}>
            {t("menu.documentation")}
          </MenubarItem>
          <MenubarItem onClick={() => handleCommand("workbench.openKeyboardShortcuts")}>
            {t("menu.keyboardShortcuts")}
          </MenubarItem>
          <MenubarItem onClick={() => handleClickEmit("menu_whats_new")}>
            {t("menu.whatsNew")}
          </MenubarItem>
          <MenubarItem onClick={() => handleClickEmit("menu_changelog")}>
            {t("menu.changelog")}
          </MenubarItem>
          <MenubarSeparator />
          <MenubarItem onClick={() => handleClickEmit("menu_report_bug")}>
            {t("menu.reportBug")}
          </MenubarItem>
          <MenubarItem onClick={() => handleClickEmit("menu_request_feature")}>
            {t("menu.requestFeature")}
          </MenubarItem>
          <MenubarSeparator />
          <MenubarItem onClick={() => handleClickEmit("menu_check_updates")}>
            {t("menu.checkForUpdates")}
          </MenubarItem>
        </MenubarContent>
      ),
    }),
    [closeMenu, handleClickEmit, handleCommand, handleNewWindow, t, themes],
  );

  return (
    <div
      className={cn(
        "z-100000 flex flex-col",
        compactMenuBar && compactFloating && "absolute top-full left-0 mt-1 w-max",
        compactMenuBar && !compactFloating && "absolute inset-0",
      )}
    >
      <Menubar
        value={activeMenu ?? ""}
        onValueChange={(value) => setActiveMenu(value || null)}
        className={cn(
          compactMenuBar &&
            compactFloating &&
            "h-auto w-max flex-nowrap rounded-2xl border border-border bg-background/95 px-1 py-1 shadow-(--shadow-popover) backdrop-blur-sm",
          compactMenuBar &&
            !compactFloating &&
            "h-full rounded-none border-none bg-transparent px-2 py-0",
        )}
      >
        {Object.entries(menus).map(([menuName, menuContent]) => (
          <MenubarMenu key={menuName} value={menuName}>
            <MenubarTrigger
              disabled={
                (menuName === "Terminal" && !isBackendCapabilityAvailable("terminal")) ||
                (menuName === "Run" && !isBackendCapabilityAvailable("debugger"))
              }
              title={
                (menuName === "Terminal" && !isBackendCapabilityAvailable("terminal")) ||
                (menuName === "Run" && !isBackendCapabilityAvailable("debugger"))
                  ? BACKEND_UNAVAILABLE_TOOLTIP
                  : undefined
              }
            >
              {t(`menu.${menuName.toLowerCase()}`)}
            </MenubarTrigger>
            {menuContent}
          </MenubarMenu>
        ))}
      </Menubar>
    </div>
  );
};

export default WindowMenuBar;
