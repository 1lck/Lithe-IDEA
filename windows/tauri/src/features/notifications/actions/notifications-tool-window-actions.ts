import { useUIState } from "@/features/window/stores/ui-state.store";

const NOTIFICATIONS_TOOL_WINDOW_VIEW = "notifications";

type NotificationsToolWindowIntent = "open" | "close" | "toggle";

interface NotificationsToolWindowState {
  activeRightSidebarView: string;
  isRightSidebarVisible: boolean;
}

interface NotificationsToolWindowUpdate {
  activeRightSidebarView: string;
  isRightSidebarVisible: boolean;
}

export function resolveNotificationsToolWindowUpdate(
  state: NotificationsToolWindowState,
  intent: NotificationsToolWindowIntent,
): NotificationsToolWindowUpdate {
  const isNotificationsVisible =
    state.isRightSidebarVisible && state.activeRightSidebarView === NOTIFICATIONS_TOOL_WINDOW_VIEW;

  if (intent === "close" || (intent === "toggle" && isNotificationsVisible)) {
    return {
      activeRightSidebarView: state.activeRightSidebarView,
      isRightSidebarVisible: false,
    };
  }

  return {
    activeRightSidebarView: NOTIFICATIONS_TOOL_WINDOW_VIEW,
    isRightSidebarVisible: true,
  };
}

function applyNotificationsToolWindowIntent(intent: NotificationsToolWindowIntent): void {
  const state = useUIState.getState();
  const update = resolveNotificationsToolWindowUpdate(state, intent);

  if (update.activeRightSidebarView !== state.activeRightSidebarView) {
    state.setActiveRightSidebarView(update.activeRightSidebarView);
  }
  if (update.isRightSidebarVisible !== state.isRightSidebarVisible) {
    state.setIsRightSidebarVisible(update.isRightSidebarVisible);
  }
}

export function openNotificationsToolWindow(): void {
  applyNotificationsToolWindowIntent("open");
}

export function closeNotificationsToolWindow(): void {
  applyNotificationsToolWindowIntent("close");
}

export function toggleNotificationsToolWindow(): void {
  applyNotificationsToolWindowIntent("toggle");
}
