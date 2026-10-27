import { useBuildSystemsCatalogStore } from "@/features/build-systems/build-systems-service";
import { toggleBuildSystemWindow } from "@/features/build-systems/actions/build-system-tool-window-actions";
import { useDeclarativePluginUI } from "@/features/plugins/declarative-plugin-ui";
import { openDeclarativeWebWindow } from "@/features/plugins/declarative-plugin-launch";
import { NativeContributionButton } from "@/features/plugins/native-ui/native-contribution-button";
import type { NativeContribution } from "@/features/plugins/native-ui/native-ui.types";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { AgentTrigger } from "@/features/agent/components/agent-trigger";
import {
  toggleMavenPane,
  toggleTerminalPane,
} from "@/features/keymaps/commands/view-command-actions";
import { isBackendCapabilityAvailable } from "@/config/backend-capabilities";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { MavenIcon } from "@/features/maven/components/maven-icon";
import { useMavenStore } from "@/features/maven/stores/maven.store";
import { NotificationsTrigger } from "@/features/notifications/components/notifications-trigger";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { buildSystemViewId } from "@/features/build-systems/build-systems-store";
import type { BuildCatalogEntry } from "@/features/build-systems/build-systems-types";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { PuzzlePieceIcon, TerminalWindowIcon } from "@/ui/icons";
import { useTerminalDock } from "./terminal-dock-layout";

// IntelliJ Islands stripe button: 30px highlight, 12px arc (6px radius), 20px icon.
const STRIPE_BUTTON_CLASS_NAME = "size-[30px] rounded-[6px]";
const NO_NATIVE_WINDOWS: NativeContribution[] = [];

export function PluginActivityRail() {
  const { t } = useTranslation();
  const pluginWindows = useDeclarativePluginUI((state) => state.windows);
  const nativeWindows = useDeclarativePluginUI((state) => state.nativeWindows ?? NO_NATIVE_WINDOWS);
  const terminalDock = useTerminalDock();
  const terminalEnabled = useSettingsStore((state) => state.settings.coreFeatures.terminal);
  const terminalHidden = useSettingsStore((state) =>
    state.settings.hiddenSidebarActivityItems.includes("terminal"),
  );
  const isTerminalActive = useUIState(
    (state) => state.isBottomPaneVisible && state.bottomPaneActiveTab === "terminal",
  );
  const openExtensionsBuffer = useBufferStore.use.actions().openExtensionsBuffer;
  const closeBuffer = useBufferStore.use.actions().closeBuffer;
  const activeExtensionsBufferId = useBufferStore((state) => {
    if (!state.activeBufferId) return null;

    const activeBuffer = state.buffers.find((buffer) => buffer.id === state.activeBufferId);
    return activeBuffer?.type === "extensions" ? activeBuffer.id : null;
  });
  const isExtensionsActive = activeExtensionsBufferId !== null;

  // The Extensions page is a singleton buffer: a second click while it is the
  // active tab closes it, otherwise the click opens or focuses it.
  const toggleExtensionsBuffer = () => {
    if (activeExtensionsBufferId) {
      closeBuffer(activeExtensionsBufferId);
      return;
    }
    openExtensionsBuffer();
  };
  const isMavenAvailable = useMavenStore(
    (state) => Boolean(state.project) || state.projectStatus === "failed",
  );
  const buildSystemEntries = useBuildSystemsCatalogStore((state) => state.entries);
  const isMavenActive = useUIState(
    (state) => state.isRightSidebarVisible && state.activeRightSidebarView === "maven",
  );
  const activityViewsLabel = t("workbench.activityViews");
  const extensionsLabel = t("extensions.title");
  const mavenLabel = t("workbench.maven");

  return (
    <aside
      aria-label={activityViewsLabel}
      className="lithe-plugin-activity-rail flex w-9.5 shrink-0 flex-col items-center gap-2.5 bg-surface pt-1"
    >
      <Button
        type="button"
        variant="ghost"
        size="icon-sm"
        active={isExtensionsActive}
        tooltip={extensionsLabel}
        tooltipSide="left"
        aria-label={extensionsLabel}
        aria-pressed={isExtensionsActive}
        className={STRIPE_BUTTON_CLASS_NAME}
        onClick={toggleExtensionsBuffer}
      >
        <PuzzlePieceIcon className="size-5" />
      </Button>
      {pluginWindows.map((window) => (
        <Button
          key={`${window.pluginId}:${window.windowId}`}
          variant="ghost"
          size="icon-sm"
          className={STRIPE_BUTTON_CLASS_NAME}
          tooltip={window.title}
          aria-label={window.title}
          onClick={() => {
            void openDeclarativeWebWindow(window.pluginId, window.windowId).catch(console.error);
          }}
        >
          <PuzzlePieceIcon className="size-5" />
        </Button>
      ))}
      <NotificationsTrigger className={STRIPE_BUTTON_CLASS_NAME} />
      {nativeWindows.map((entry) => (
        <NativeContributionButton
          key={`${entry.pluginId}:${entry.windowId}`}
          className={STRIPE_BUTTON_CLASS_NAME}
          entry={entry}
        />
      ))}
      <AgentTrigger className={STRIPE_BUTTON_CLASS_NAME} />
      {isMavenAvailable ? (
        <Button
          type="button"
          variant="ghost"
          size="icon-sm"
          active={isMavenActive}
          tooltip={mavenLabel}
          tooltipSide="left"
          aria-label={mavenLabel}
          aria-pressed={isMavenActive}
          className={STRIPE_BUTTON_CLASS_NAME}
          onClick={toggleMavenPane}
        >
          <MavenIcon className="size-5" />
        </Button>
      ) : null}
      {buildSystemEntries.map((entry) => (
        <BuildSystemRailButton key={`${entry.pluginId}:${entry.buildSystemId}`} entry={entry} />
      ))}
      {terminalDock?.activitySide === "right" &&
      terminalEnabled &&
      !terminalHidden &&
      isBackendCapabilityAvailable("terminal") ? (
        <div className="mt-auto pb-1">
          <Button
            variant="ghost"
            size="icon-sm"
            className={`${STRIPE_BUTTON_CLASS_NAME} cursor-grab touch-none`}
            active={isTerminalActive}
            aria-pressed={isTerminalActive}
            aria-label={t("workbench.terminal")}
            tooltip={t("workbench.terminal")}
            commandId="workbench.toggleTerminal"
            tooltipSide="left"
            data-terminal-dock-activity="right"
            onPointerDown={(event) => terminalDock.startDrag(event, true)}
            onClick={(event) => {
              if (!terminalDock.suppressActivityClick(event.detail === 0)) toggleTerminalPane();
            }}
          >
            <TerminalWindowIcon className="size-5" />
          </Button>
        </div>
      ) : null}
    </aside>
  );
}

function BuildSystemRailButton({ entry }: { entry: BuildCatalogEntry }) {
  const { t } = useTranslation();
  const viewId = buildSystemViewId(entry.pluginId, entry.buildSystemId);
  const isActive = useUIState(
    (state) => state.isRightSidebarVisible && state.activeRightSidebarView === viewId,
  );
  const label =
    entry.buildSystemDisplayName || t("buildSystems.railLabel", { name: entry.pluginDisplayName });

  return (
    <Button
      type="button"
      variant="ghost"
      size="icon-sm"
      active={isActive}
      tooltip={label}
      tooltipSide="left"
      aria-label={label}
      aria-pressed={isActive}
      className={STRIPE_BUTTON_CLASS_NAME}
      onClick={() => toggleBuildSystemWindow(entry)}
    >
      <PuzzlePieceIcon className="size-5" />
    </Button>
  );
}
