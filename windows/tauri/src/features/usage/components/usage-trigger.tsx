import {
  USAGE_TOOL_WINDOW_VIEW,
  toggleUsageToolWindow,
} from "../actions/usage-tool-window-actions";
import { useCommandShortcut } from "@/features/keymaps/hooks/use-command-shortcut";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { PulseIcon } from "@/ui/icons";
import { cn } from "@/utils/cn";

interface UsageTriggerProps {
  className?: string;
}

/**
 * The rail button that opens the usage tool window. It carries no badge of its
 * own: the status bar chip already reports how tight the subscription is, and
 * polling the endpoint twice for the same answer would not make it truer.
 */
export const UsageTrigger = ({ className }: UsageTriggerProps) => {
  const { t } = useTranslation();
  const isRightSidebarVisible = useUIState((state) => state.isRightSidebarVisible);
  const activeRightSidebarView = useUIState((state) => state.activeRightSidebarView);
  const shortcut = useCommandShortcut("workbench.showUsage");
  const isActive = isRightSidebarVisible && activeRightSidebarView === USAGE_TOOL_WINDOW_VIEW;

  return (
    <Button
      onClick={toggleUsageToolWindow}
      type="button"
      variant="ghost"
      size="icon-sm"
      active={isActive}
      className={cn("rounded-sm", className)}
      tooltip={t("usageStats.title")}
      shortcut={shortcut}
      tooltipSide="left"
      aria-label={t("usageStats.title")}
      aria-pressed={isActive}
    >
      <PulseIcon className="size-4.5" />
    </Button>
  );
};
