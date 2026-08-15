import { useMemo } from "react";
import {
  BACKEND_UNAVAILABLE_TOOLTIP,
  isBackendCapabilityAvailable,
} from "@/config/backend-capabilities";
import { useDiagnosticsStore } from "@/features/diagnostics/stores/diagnostics.store";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { NotificationsTrigger } from "@/features/notifications/components/notifications-trigger";
import {
  FOOTER_TRAILING_ITEM_IDS,
  normalizeItemOrder,
  type FooterLeadingItemId,
  type FooterTrailingItemId,
} from "@/features/layout/config/item-order";
import { orderChromeItems, type ChromeItem } from "@/features/layout/utils/chrome-items";
import { useFooterGitBranchItem } from "./footer-git-branch-item";
import { FooterTabControl } from "./footer-tab-control";
import {
  DatabaseIcon,
  TerminalWindowIcon,
  WarningIcon,
} from "@/ui/icons";
import { ChromeBar, ChromeGroup } from "@/ui/chrome";

const Footer = () => {
  const terminalEnabled = useSettingsStore((state) => state.settings.coreFeatures.terminal);
  const diagnosticsEnabled = useSettingsStore((state) => state.settings.coreFeatures.diagnostics);
  const footerLeadingItemsOrder = useSettingsStore(
    (state) => state.settings.footerLeadingItemsOrder,
  );
  const footerTrailingItemsOrder = useSettingsStore(
    (state) => state.settings.footerTrailingItemsOrder,
  );
  const isCommandPaletteVisible = useUIState((state) => state.isCommandPaletteVisible);
  const commandPaletteInitialView = useUIState((state) => state.commandPaletteInitialView);
  const isBottomPaneVisible = useUIState((state) => state.isBottomPaneVisible);
  const bottomPaneActiveTab = useUIState((state) => state.bottomPaneActiveTab);
  const setIsBottomPaneVisible = useUIState((state) => state.setIsBottomPaneVisible);
  const setBottomPaneActiveTab = useUIState((state) => state.setBottomPaneActiveTab);
  const openCommandPaletteView = useUIState((state) => state.openCommandPaletteView);
  const isDiagnosticsBufferActive = useBufferStore((state) => {
    if (!state.activeBufferId) return false;
    return state.buffers.some(
      (buffer) => buffer.id === state.activeBufferId && buffer.type === "diagnostics",
    );
  });
  const openDiagnosticsBuffer = useBufferStore.use.actions().openDiagnosticsBuffer;
  const branchItem = useFooterGitBranchItem();
  const diagnosticsByFile = useDiagnosticsStore.use.diagnosticsByFile();
  const diagnosticsCount = Array.from(diagnosticsByFile.values()).reduce(
    (total, diagnostics) => total + diagnostics.length,
    0,
  );
  const footerLeadingItemsSource: Array<ChromeItem<FooterLeadingItemId> | null> = [
    branchItem,
    terminalEnabled
      ? {
          id: "terminal",
          label: "Terminal",
          content: (
            <FooterTabControl
              tooltip={
                isBackendCapabilityAvailable("terminal")
                  ? "Toggle Terminal"
                  : BACKEND_UNAVAILABLE_TOOLTIP
              }
              disabled={!isBackendCapabilityAvailable("terminal")}
              active={isBottomPaneVisible && bottomPaneActiveTab === "terminal"}
              commandId="workbench.toggleTerminal"
              onClick={() => {
                setBottomPaneActiveTab("terminal");
                const showingTerminal = !isBottomPaneVisible || bottomPaneActiveTab !== "terminal";
                setIsBottomPaneVisible(showingTerminal);
              }}
            >
              <TerminalWindowIcon />
            </FooterTabControl>
          ),
        }
      : null,
    diagnosticsEnabled
      ? {
          id: "diagnostics",
          label: "Diagnostics",
          content: (
            <FooterTabControl
              tooltip={
                diagnosticsCount > 0
                  ? `${diagnosticsCount} diagnostic${diagnosticsCount === 1 ? "" : "s"}`
                  : "Open Diagnostics"
              }
              active={isDiagnosticsBufferActive}
              tone={!isDiagnosticsBufferActive && diagnosticsCount > 0 ? "warning" : "default"}
              commandId="workbench.toggleDiagnostics"
              onClick={() => openDiagnosticsBuffer()}
            >
              <WarningIcon />
              {diagnosticsCount > 0 && <span className="tabular-nums">{diagnosticsCount}</span>}
            </FooterTabControl>
          ),
        }
      : null,
  ];
  const footerLeadingItems = footerLeadingItemsSource.filter(
    (item): item is ChromeItem<FooterLeadingItemId> => item !== null,
  );
  const isDatabasesActive = isCommandPaletteVisible && commandPaletteInitialView === "databases";
  const footerTrailingOrder = useMemo<FooterTrailingItemId[]>(() => {
    return normalizeItemOrder(
      footerTrailingItemsOrder,
      FOOTER_TRAILING_ITEM_IDS,
    ) as FooterTrailingItemId[];
  }, [footerTrailingItemsOrder]);

  const footerTrailingItems: Array<ChromeItem<FooterTrailingItemId>> = [
    {
      id: "databases",
      label: "Databases",
      content: (
        <FooterTabControl
          tooltip={
            isBackendCapabilityAvailable("database") ? "Databases" : BACKEND_UNAVAILABLE_TOOLTIP
          }
          disabled={!isBackendCapabilityAvailable("database")}
          active={isDatabasesActive}
          commandId="database.connect"
          onClick={() => {
            openCommandPaletteView("databases");
          }}
        >
          <DatabaseIcon />
        </FooterTabControl>
      ),
    },
    {
      id: "notifications",
      label: "Notifications",
      content: <NotificationsTrigger />,
    },
  ];

  return (
    <ChromeBar
      region="footer"
      className="lithe-footer-bar relative z-20 justify-between"
      aria-label="Status bar"
    >
      <ChromeGroup gap="tight">
        {orderChromeItems(footerLeadingItems, footerLeadingItemsOrder).map((item) => (
          <div key={item.id} className="flex min-h-(--lithe-chrome-control-height) items-center">
            {item.content}
          </div>
        ))}
      </ChromeGroup>

      <ChromeGroup gap="tight">
        {orderChromeItems(footerTrailingItems, footerTrailingOrder).map((item) => (
          <div key={item.id} className="flex min-h-(--lithe-chrome-control-height) items-center">
            {item.content}
          </div>
        ))}
      </ChromeGroup>
    </ChromeBar>
  );
};

export default Footer;
