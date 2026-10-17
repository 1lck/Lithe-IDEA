import { useCommandShortcut } from "@/features/keymaps/hooks/use-command-shortcut";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { ChatCircleTextIcon } from "@/ui/icons";
import { cn } from "@/utils/cn";
import { toggleAgentToolWindow } from "../actions/agent-tool-window-actions";

/**
 * The Agent entry in the right activity rail.
 *
 * It stays visible whether or not the feature is on, matching the macOS entry
 * policy: a new install must be able to find the panel and read why it is off.
 */
export function AgentTrigger({ className }: { className?: string }) {
  const { t } = useTranslation();
  const isRightSidebarVisible = useUIState((state) => state.isRightSidebarVisible);
  const activeRightSidebarView = useUIState((state) => state.activeRightSidebarView);
  const shortcut = useCommandShortcut("workbench.showAgent");
  const isActive = isRightSidebarVisible && activeRightSidebarView === "agent";

  return (
    <Button
      onClick={toggleAgentToolWindow}
      type="button"
      variant="ghost"
      size="icon-sm"
      active={isActive}
      className={cn("rounded-sm", className)}
      tooltip={t("agent.title")}
      shortcut={shortcut}
      tooltipSide="left"
      aria-label={t("agent.title")}
      aria-pressed={isActive}
    >
      <ChatCircleTextIcon className="size-4.5" />
    </Button>
  );
}
