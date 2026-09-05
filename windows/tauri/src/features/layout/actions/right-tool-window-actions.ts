import type { SidebarView } from "@/features/layout/utils/sidebar-pane-utils";
import { useUIState } from "@/features/window/stores/ui-state.store";

export type RightToolWindowIntent = "open" | "close" | "toggle";

export interface RightToolWindowState {
  activeRightSidebarView: SidebarView;
  isRightSidebarVisible: boolean;
}

export function resolveRightToolWindowUpdate(
  state: RightToolWindowState,
  view: SidebarView,
  intent: RightToolWindowIntent,
): RightToolWindowState {
  const isActive = state.activeRightSidebarView === view;
  const isVisible = state.isRightSidebarVisible && isActive;

  if (intent === "close") {
    return {
      activeRightSidebarView: state.activeRightSidebarView,
      isRightSidebarVisible: isActive ? false : state.isRightSidebarVisible,
    };
  }

  if (intent === "toggle" && isVisible) {
    return {
      activeRightSidebarView: state.activeRightSidebarView,
      isRightSidebarVisible: false,
    };
  }

  return {
    activeRightSidebarView: view,
    isRightSidebarVisible: true,
  };
}

export function applyRightToolWindowIntent(view: SidebarView, intent: RightToolWindowIntent): void {
  const state = useUIState.getState();
  const update = resolveRightToolWindowUpdate(state, view, intent);

  if (update.activeRightSidebarView !== state.activeRightSidebarView) {
    state.setActiveRightSidebarView(update.activeRightSidebarView);
  }
  if (update.isRightSidebarVisible !== state.isRightSidebarVisible) {
    state.setIsRightSidebarVisible(update.isRightSidebarVisible);
  }
}
