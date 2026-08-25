import { useMemo } from "react";
import { useCommandShortcut } from "@/features/keymaps/hooks/use-command-shortcut";
import { toggleNotificationsToolWindow } from "@/features/notifications/actions/notifications-tool-window-actions";
import { useNotificationsStore } from "@/features/notifications/stores/notifications.store";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { Button } from "@/ui/button";
import { BellIcon } from "@/ui/icons";
import { cn } from "@/utils/cn";
import { useTranslation } from "@/i18n/locale-provider";

interface NotificationsTriggerProps {
  className?: string;
}

export const NotificationsTrigger = ({ className }: NotificationsTriggerProps) => {
  const { t } = useTranslation();
  const notifications = useNotificationsStore.use.notifications();
  const isRightSidebarVisible = useUIState((state) => state.isRightSidebarVisible);
  const activeRightSidebarView = useUIState((state) => state.activeRightSidebarView);
  const shortcut = useCommandShortcut("workbench.showNotifications");
  const isActive = isRightSidebarVisible && activeRightSidebarView === "notifications";
  const unreadCount = useMemo(
    () =>
      notifications.filter((notification) => !notification.read && notification.type !== "success")
        .length,
    [notifications],
  );

  return (
    <Button
      onClick={toggleNotificationsToolWindow}
      type="button"
      variant="ghost"
      size="icon-sm"
      active={isActive}
      className={cn("relative rounded-sm", className)}
      tooltip={t("notifications.title")}
      shortcut={shortcut}
      tooltipSide="left"
      aria-label={t("notifications.title")}
      aria-pressed={isActive}
    >
      <BellIcon className="size-4.5" />
      {unreadCount > 0 ? (
        <span className="pointer-events-none absolute top-0 right-0 flex min-w-3 translate-x-0.5 -translate-y-0.5 items-center justify-center rounded-full bg-primary px-0.5 font-sans text-[9px] leading-3 text-primary-foreground tabular-nums">
          {unreadCount > 9 ? "9+" : unreadCount}
        </span>
      ) : null}
    </Button>
  );
};
