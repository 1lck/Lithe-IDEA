import { useCommandShortcut } from "@/features/keymaps/hooks/use-command-shortcut";
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
  compactExpanded?: boolean;
  onCompactClose?: () => void;
}

/** Labels follow the effective preset/user binding; actions keep their existing owner. */
function CommandMenuItem({
  commandId,
  ...props
}: React.ComponentProps<typeof MenubarItem> & { commandId: string }) {
  const shortcut = useCommandShortcut(commandId);
  return <MenubarItem {...props} shortcut={shortcut} />;
}

const WindowMenuBar = ({
  activeMenu,
  setActiveMenu,
  compactExpanded = false,
  onCompactClose,
}: Props) => {
  const { t } = useTranslation();
  const themes = useRegisteredThemes();
  const menuWindowRaiseRef = useRef<{ restoreTo: boolean } | null>(null);
  const firstMenuTriggerRef = useRef<HTMLButtonElement>(null);
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

  useEffect(() => {
    if (compactExpanded) firstMenuTriggerRef.current?.focus();
  }, [compactExpanded]);

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
          <CommandMenuItem
            commandId="workbench.newTab"
            onClick={() => handleCommand("workbench.newTab")}
          >
            {t("menu.newTab")}
          </CommandMenuItem>
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
          <CommandMenuItem commandId="file.saveAll" onClick={() => handleCommand("file.saveAll")}>
            {t("menu.saveAll")}
          </CommandMenuItem>
          <CommandMenuItem commandId="file.revert" onClick={() => handleCommand("file.revert")}>
            {t("menu.revertFile")}
          </CommandMenuItem>
          <CommandMenuItem
            commandId="file.localHistory"
            onClick={() => handleCommand("file.localHistory")}
          >
            {t("menu.showLocalHistory")}
          </CommandMenuItem>
          <MenubarSeparator />
          <CommandMenuItem commandId="file.close" onClick={() => handleClickEmit("menu_close_tab")}>
            {t("menu.closeTab")}
          </CommandMenuItem>
          <CommandMenuItem
            commandId="workbench.closeWindow"
            onClick={() => handleCommand("workbench.closeWindow")}
          >
            {t("menu.closeWindow")}
          </CommandMenuItem>
          <CommandMenuItem commandId="file.closeAll" onClick={() => handleCommand("file.closeAll")}>
            {t("menu.closeAllTabs")}
          </CommandMenuItem>
          <CommandMenuItem
            commandId="file.closeOthers"
            onClick={() => handleCommand("file.closeOthers")}
          >
            {t("menu.closeOtherTabs")}
          </CommandMenuItem>
          <CommandMenuItem
            commandId="file.closeSaved"
            onClick={() => handleCommand("file.closeSaved")}
          >
            {t("menu.closeSavedTabs")}
          </CommandMenuItem>
          <CommandMenuItem
            commandId="file.closeTabsToLeft"
            onClick={() => handleCommand("file.closeTabsToLeft")}
          >
            {t("menu.closeTabsToLeft")}
          </CommandMenuItem>
          <CommandMenuItem
            commandId="file.closeTabsToRight"
            onClick={() => handleCommand("file.closeTabsToRight")}
          >
            {t("menu.closeTabsToRight")}
          </CommandMenuItem>
          <CommandMenuItem
            commandId="file.reopenClosed"
            onClick={() => handleCommand("file.reopenClosed")}
          >
            {t("menu.reopenClosedTab")}
          </CommandMenuItem>
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
          <CommandMenuItem commandId="editor.redo" onClick={() => handleClickEmit("menu_redo")}>
            {t("menu.redo")}
          </CommandMenuItem>
          <MenubarSeparator />
          <CommandMenuItem commandId="editor.cut" onClick={() => handleCommand("editor.cut")}>
            {t("menu.cut")}
          </CommandMenuItem>
          <CommandMenuItem commandId="editor.copy" onClick={() => handleCommand("editor.copy")}>
            {t("menu.copy")}
          </CommandMenuItem>
          <CommandMenuItem commandId="editor.paste" onClick={() => handleCommand("editor.paste")}>
            {t("menu.paste")}
          </CommandMenuItem>
          <CommandMenuItem
            commandId="editor.selectAll"
            onClick={() => handleCommand("editor.selectAll")}
          >
            {t("menu.selectAll")}
          </CommandMenuItem>
          <MenubarSeparator />
          <MenubarItem shortcut="mod+f" onClick={() => handleClickEmit("menu_find")}>
            {t("menu.find")}
          </MenubarItem>
          <CommandMenuItem
            commandId="workbench.showFindReplace"
            onClick={() => handleClickEmit("menu_find_replace")}
          >
            {t("menu.findAndReplace")}
          </CommandMenuItem>
          <CommandMenuItem
            commandId="editor.toggleComment"
            onClick={() => handleClickEmit("menu_toggle_comment")}
          >
            {t("menu.toggleComment")}
          </CommandMenuItem>
          <CommandMenuItem
            commandId="editor.quickFix"
            onClick={() => handleCommand("editor.quickFix")}
          >
            {t("menu.quickFix")}
          </CommandMenuItem>
          <CommandMenuItem
            commandId="editor.triggerParameterHints"
            onClick={() => handleCommand("editor.triggerParameterHints")}
          >
            {t("menu.triggerParameterHints")}
          </CommandMenuItem>
          <CommandMenuItem
            commandId="editor.showHover"
            onClick={() => handleCommand("editor.showHover")}
          >
            {t("menu.showHover")}
          </CommandMenuItem>
          <MenubarSeparator />
          <CommandMenuItem
            commandId="editor.duplicateLine"
            onClick={() => handleCommand("editor.duplicateLine")}
          >
            {t("menu.duplicateLine")}
          </CommandMenuItem>
          <CommandMenuItem
            commandId="editor.deleteLine"
            onClick={() => handleCommand("editor.deleteLine")}
          >
            {t("menu.deleteLine")}
          </CommandMenuItem>
          <CommandMenuItem
            commandId="editor.moveLineUp"
            onClick={() => handleCommand("editor.moveLineUp")}
          >
            {t("menu.moveLineUp")}
          </CommandMenuItem>
          <CommandMenuItem
            commandId="editor.moveLineDown"
            onClick={() => handleCommand("editor.moveLineDown")}
          >
            {t("menu.moveLineDown")}
          </CommandMenuItem>
          <CommandMenuItem
            commandId="editor.formatDocument"
            onClick={() => handleCommand("editor.formatDocument")}
          >
            {t("menu.formatDocument")}
          </CommandMenuItem>
          <CommandMenuItem
            commandId="editor.formatSelection"
            onClick={() => handleCommand("editor.formatSelection")}
          >
            {t("menu.formatSelection")}
          </CommandMenuItem>
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
          <CommandMenuItem
            commandId="workbench.showGlobalSearch"
            onClick={() => handleCommand("workbench.showGlobalSearch")}
          >
            {t("menu.globalSearch")}
          </CommandMenuItem>
          <CommandMenuItem
            commandId="workbench.toggleDiagnostics"
            onClick={() => handleCommand("workbench.toggleDiagnostics")}
          >
            {t("menu.diagnostics")}
          </CommandMenuItem>
          <MenubarSeparator />
          <CommandMenuItem
            commandId="workbench.showFileExplorer"
            onClick={() => handleCommand("workbench.showFileExplorer")}
          >
            {t("menu.fileExplorer")}
          </CommandMenuItem>
          <CommandMenuItem
            commandId="workbench.showSourceControl"
            onClick={() => handleCommand("workbench.showSourceControl")}
          >
            {t("menu.sourceControl")}
          </CommandMenuItem>
          <CommandMenuItem
            commandId="workbench.showGitHub"
            onClick={() => handleCommand("workbench.showGitHub")}
          >
            {t("menu.github")}
          </CommandMenuItem>
          <CommandMenuItem
            commandId="workbench.showDebugger"
            onClick={() => handleCommand("workbench.showDebugger")}
          >
            {t("menu.runAndDebug")}
          </CommandMenuItem>
          <MenubarSeparator />
          <MenubarItem onClick={() => handleClickEmit("menu_split_editor")}>
            {t("menu.splitEditor")}
          </MenubarItem>
          <CommandMenuItem
            commandId="workbench.toggleMinimap"
            onClick={() => handleCommand("workbench.toggleMinimap")}
          >
            {t("menu.toggleMinimap")}
          </CommandMenuItem>
          <CommandMenuItem
            commandId="editor.toggleWordWrap"
            onClick={() => handleCommand("editor.toggleWordWrap")}
          >
            {t("menu.toggleWordWrap")}
          </CommandMenuItem>
          <CommandMenuItem
            commandId="editor.toggleLineNumbers"
            onClick={() => handleCommand("editor.toggleLineNumbers")}
          >
            {t("menu.toggleLineNumbers")}
          </CommandMenuItem>
          <CommandMenuItem
            commandId="editor.toggleRenderWhitespace"
            onClick={() => handleCommand("editor.toggleRenderWhitespace")}
          >
            {t("menu.toggleRenderWhitespace")}
          </CommandMenuItem>
          <MenubarSeparator />
          <CommandMenuItem
            commandId="workbench.zoomIn"
            onClick={() => handleCommand("workbench.zoomIn")}
          >
            {t("menu.zoomIn")}
          </CommandMenuItem>
          <CommandMenuItem
            commandId="workbench.zoomOut"
            onClick={() => handleCommand("workbench.zoomOut")}
          >
            {t("menu.zoomOut")}
          </CommandMenuItem>
          <CommandMenuItem
            commandId="workbench.zoomReset"
            onClick={() => handleCommand("workbench.zoomReset")}
          >
            {t("menu.resetZoom")}
          </CommandMenuItem>
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
          <CommandMenuItem
            commandId="navigation.goBack"
            onClick={() => handleCommand("navigation.goBack")}
          >
            {t("menu.goBack")}
          </CommandMenuItem>
          <CommandMenuItem
            commandId="navigation.goForward"
            onClick={() => handleCommand("navigation.goForward")}
          >
            {t("menu.goForward")}
          </CommandMenuItem>
          <MenubarSeparator />
          <CommandMenuItem
            commandId="editor.goToDefinition"
            onClick={() => handleCommand("editor.goToDefinition")}
          >
            {t("menu.goToDefinition")}
          </CommandMenuItem>
          <CommandMenuItem
            commandId="editor.goToImplementation"
            onClick={() => handleCommand("editor.goToImplementation")}
          >
            {t("menu.goToImplementation")}
          </CommandMenuItem>
          <CommandMenuItem
            commandId="editor.goToTypeDefinition"
            onClick={() => handleCommand("editor.goToTypeDefinition")}
          >
            {t("menu.goToTypeDefinition")}
          </CommandMenuItem>
          <CommandMenuItem
            commandId="editor.goToReferences"
            onClick={() => handleCommand("editor.goToReferences")}
          >
            {t("menu.goToReferences")}
          </CommandMenuItem>
          <CommandMenuItem
            commandId="editor.renameSymbol"
            onClick={() => handleCommand("editor.renameSymbol")}
          >
            {t("menu.renameSymbol")}
          </CommandMenuItem>
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
          <CommandMenuItem commandId="terminal.new" onClick={() => handleCommand("terminal.new")}>
            {t("menu.newTerminal")}
          </CommandMenuItem>
          <CommandMenuItem
            commandId="terminal.split"
            onClick={() => handleCommand("terminal.split")}
          >
            {t("menu.splitTerminalRight")}
          </CommandMenuItem>
          <CommandMenuItem
            commandId="terminal.splitDown"
            onClick={() => handleCommand("terminal.splitDown")}
          >
            {t("menu.splitTerminalDown")}
          </CommandMenuItem>
          <CommandMenuItem
            commandId="terminal.close"
            onClick={() => handleCommand("terminal.close")}
          >
            {t("menu.closeTerminal")}
          </CommandMenuItem>
        </MenubarContent>
      ),
      Run: (
        <MenubarContent>
          <CommandMenuItem
            commandId="run.runSelectedConfiguration"
            onClick={() => handleCommand("run.runSelectedConfiguration")}
          >
            {t("run.run")}
          </CommandMenuItem>
          <CommandMenuItem
            commandId="run.stopSelectedConfiguration"
            onClick={() => handleCommand("run.stopSelectedConfiguration")}
          >
            {t("run.stop")}
          </CommandMenuItem>
          <MenubarSeparator />
          <CommandMenuItem commandId="debug.start" onClick={() => handleCommand("debug.start")}>
            {t("menu.startDebugging")}
          </CommandMenuItem>
          <CommandMenuItem commandId="debug.stop" onClick={() => handleCommand("debug.stop")}>
            {t("menu.stopDebugging")}
          </CommandMenuItem>
          <CommandMenuItem
            commandId="debug.toggleBreakpoint"
            onClick={() => handleCommand("debug.toggleBreakpoint")}
          >
            {t("menu.toggleBreakpoint")}
          </CommandMenuItem>
        </MenubarContent>
      ),
      Tools: (
        <MenubarContent>
          <CommandMenuItem
            commandId="database.connect"
            onClick={() => handleCommand("database.connect")}
            disabled={!isBackendCapabilityAvailable("database")}
            title={BACKEND_UNAVAILABLE_TOOLTIP}
          >
            {t("menu.databases")}
          </CommandMenuItem>
          <MenubarSeparator />
          <MenubarItem shortcut="mod+alt+i" onClick={handleOpenWebInspector}>
            {t("menu.webInspector")}
          </MenubarItem>
          <MenubarSeparator />
          <MenubarItem onClick={() => handleClickEmit("menu_open_settings")}>
            {t("menu.preferences")}
          </MenubarItem>
          <CommandMenuItem
            commandId="workbench.openKeyboardShortcuts"
            onClick={() => handleCommand("workbench.openKeyboardShortcuts")}
          >
            {t("menu.keyboardShortcuts")}
          </CommandMenuItem>
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
          <CommandMenuItem
            commandId="workbench.openKeyboardShortcuts"
            onClick={() => handleCommand("workbench.openKeyboardShortcuts")}
          >
            {t("menu.keyboardShortcuts")}
          </CommandMenuItem>
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
        "z-100000 flex min-w-0",
        compactExpanded &&
          "h-full max-w-full overflow-x-auto [scrollbar-width:none] [&::-webkit-scrollbar]:hidden",
      )}
    >
      <Menubar
        value={activeMenu ?? ""}
        onValueChange={(value) => setActiveMenu(value || null)}
        className={cn(
          compactExpanded &&
            "h-full w-max flex-nowrap rounded-none border-none bg-transparent px-0 py-0",
        )}
      >
        {Object.entries(menus).map(([menuName, menuContent]) => (
          <MenubarMenu key={menuName} value={menuName}>
            <MenubarTrigger
              ref={compactExpanded && menuName === "File" ? firstMenuTriggerRef : undefined}
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
