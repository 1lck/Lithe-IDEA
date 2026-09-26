import {
  applyRightToolWindowIntent,
  resolveRightToolWindowUpdate,
  type RightToolWindowIntent,
  type RightToolWindowState,
} from "@/features/layout/actions/right-tool-window-actions";

export const USAGE_TOOL_WINDOW_VIEW = "usage";

export function resolveUsageToolWindowUpdate(
  state: RightToolWindowState,
  intent: RightToolWindowIntent,
): RightToolWindowState {
  return resolveRightToolWindowUpdate(state, USAGE_TOOL_WINDOW_VIEW, intent);
}

function applyUsageToolWindowIntent(intent: RightToolWindowIntent): void {
  applyRightToolWindowIntent(USAGE_TOOL_WINDOW_VIEW, intent);
}

export function openUsageToolWindow(): void {
  applyUsageToolWindowIntent("open");
}

export function closeUsageToolWindow(): void {
  applyUsageToolWindowIntent("close");
}

export function toggleUsageToolWindow(): void {
  applyUsageToolWindowIntent("toggle");
}