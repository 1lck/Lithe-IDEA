import { useUIState } from "@/features/window/stores/ui-state.store";

interface RunDecisionPaneUpdate {
  bottomPaneActiveTab: "run";
  isBottomPaneVisible: true;
}

/** A launch decision must be visible even when Debug started from another tool window. */
export function resolveRunDecisionPaneUpdate(): RunDecisionPaneUpdate {
  return {
    bottomPaneActiveTab: "run",
    isBottomPaneVisible: true,
  };
}

export function openRunDecisionPane(workspaceId: string): void {
  const state = useUIState.getStore(workspaceId).getState();
  const update = resolveRunDecisionPaneUpdate();
  if (state.bottomPaneActiveTab !== update.bottomPaneActiveTab) {
    state.setBottomPaneActiveTab(update.bottomPaneActiveTab);
  }
  if (state.isBottomPaneVisible !== update.isBottomPaneVisible) {
    state.setIsBottomPaneVisible(update.isBottomPaneVisible);
  }
}
