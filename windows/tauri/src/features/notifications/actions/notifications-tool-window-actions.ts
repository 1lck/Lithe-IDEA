import {
  applyRightToolWindowIntent,
  resolveRightToolWindowUpdate,
  type RightToolWindowIntent,
  type RightToolWindowState,
} from "@/features/layout/actions/right-tool-window-actions";

const NOTIFICATIONS_TOOL_WINDOW_VIEW = "notifications";

export function resolveNotificationsToolWindowUpdate(
  state: RightToolWindowState,
  intent: RightToolWindowIntent,
): RightToolWindowState {
  return resolveRightToolWindowUpdate(state, NOTIFICATIONS_TOOL_WINDOW_VIEW, intent);
}

function applyNotificationsToolWindowIntent(intent: RightToolWindowIntent): void {
  applyRightToolWindowIntent(NOTIFICATIONS_TOOL_WINDOW_VIEW, intent);
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
