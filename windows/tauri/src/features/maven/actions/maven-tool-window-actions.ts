import { applyRightToolWindowIntent } from "@/features/layout/actions/right-tool-window-actions";
import type { BottomPaneTab } from "@/features/window/stores/ui-state/types/ui-state.types";
import { useUIState } from "@/features/window/stores/ui-state.store";

const MAVEN_TOOL_WINDOW_VIEW = "maven";

interface MavenRunPaneUpdate {
  bottomPaneActiveTab: BottomPaneTab;
  isBottomPaneVisible: boolean;
}

interface MavenRunPaneState {
  bottomPaneActiveTab: BottomPaneTab;
  isBottomPaneVisible: boolean;
}

export function resolveMavenRunPaneUpdate(): MavenRunPaneUpdate {
  return {
    bottomPaneActiveTab: "maven",
    isBottomPaneVisible: true,
  };
}

export function resolveMavenRunPaneToggleUpdate(state: MavenRunPaneState): MavenRunPaneUpdate {
  if (state.isBottomPaneVisible && state.bottomPaneActiveTab === "maven") {
    return {
      bottomPaneActiveTab: state.bottomPaneActiveTab,
      isBottomPaneVisible: false,
    };
  }

  return resolveMavenRunPaneUpdate();
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

export function toggleMavenRunPane(): void {
  const state = useUIState.getState();
  applyMavenRunPaneUpdate(resolveMavenRunPaneToggleUpdate(state));
}

export function closeMavenToolWindow(): void {
  applyRightToolWindowIntent(MAVEN_TOOL_WINDOW_VIEW, "close");
}

export function toggleMavenToolWindow(): void {
  applyRightToolWindowIntent(MAVEN_TOOL_WINDOW_VIEW, "toggle");
}
