import { applyRightToolWindowIntent } from "@/features/layout/actions/right-tool-window-actions";
import type { BottomPaneTab } from "@/features/window/stores/ui-state/types/ui-state.types";
import { useUIState } from "@/features/window/stores/ui-state.store";

const MAVEN_TOOL_WINDOW_VIEW = "maven";

interface MavenRunPaneUpdate {
  bottomPaneActiveTab: BottomPaneTab;
  isBottomPaneVisible: boolean;
}

export function resolveMavenRunPaneUpdate(): MavenRunPaneUpdate {
  return {
    bottomPaneActiveTab: "maven",
    isBottomPaneVisible: true,
  };
}

function applyMavenRunPaneUpdate(update: MavenRunPaneUpdate): void {
  const state = useUIState.getState();
  if (state.bottomPaneActiveTab !== update.bottomPaneActiveTab) {
    state.setBottomPaneActiveTab(update.bottomPaneActiveTab);
  }
  if (state.isBottomPaneVisible !== update.isBottomPaneVisible) {
    state.setIsBottomPaneVisible(update.isBottomPaneVisible);
  }
}

export function openMavenRunPane(): void {
  applyMavenRunPaneUpdate(resolveMavenRunPaneUpdate());
}

export function closeMavenToolWindow(): void {
  applyRightToolWindowIntent(MAVEN_TOOL_WINDOW_VIEW, "close");
}

export function toggleMavenToolWindow(): void {
  applyRightToolWindowIntent(MAVEN_TOOL_WINDOW_VIEW, "toggle");
}
