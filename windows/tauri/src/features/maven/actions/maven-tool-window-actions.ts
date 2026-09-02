import { applyRightToolWindowIntent } from "@/features/layout/actions/right-tool-window-actions";
import { useUIState } from "@/features/window/stores/ui-state.store";

const MAVEN_TOOL_WINDOW_VIEW = "maven";

interface MavenRunPaneUpdate {
  bottomPaneActiveTab: "maven";
  isBottomPaneVisible: true;
}

export function resolveMavenRunPaneUpdate(): MavenRunPaneUpdate {
  return {
    bottomPaneActiveTab: "maven",
    isBottomPaneVisible: true,
  };
}

export function openMavenRunPane(): void {
  const state = useUIState.getState();
  const update = resolveMavenRunPaneUpdate();
  if (state.bottomPaneActiveTab !== update.bottomPaneActiveTab) {
    state.setBottomPaneActiveTab(update.bottomPaneActiveTab);
  }
  if (!state.isBottomPaneVisible) {
    state.setIsBottomPaneVisible(update.isBottomPaneVisible);
  }
}

export function closeMavenToolWindow(): void {
  applyRightToolWindowIntent(MAVEN_TOOL_WINDOW_VIEW, "close");
}

export function toggleMavenToolWindow(): void {
  applyRightToolWindowIntent(MAVEN_TOOL_WINDOW_VIEW, "toggle");
}
