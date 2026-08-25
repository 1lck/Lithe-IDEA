import { useUIState } from "@/features/window/stores/ui-state.store";

interface DiagnosticsPaneState {
  bottomPaneActiveTab: string;
  isBottomPaneVisible: boolean;
}

interface DiagnosticsPaneUpdate {
  bottomPaneActiveTab: "diagnostics";
  isBottomPaneVisible: boolean;
}

interface GlobalSearchSidebarUpdate {
  activeSidebarView: "search";
  isSidebarVisible: true;
}

export function resolveDiagnosticsPaneUpdate(state: DiagnosticsPaneState): DiagnosticsPaneUpdate {
  return {
    bottomPaneActiveTab: "diagnostics",
    isBottomPaneVisible: !(
      state.isBottomPaneVisible && state.bottomPaneActiveTab === "diagnostics"
    ),
  };
}

export function toggleDiagnosticsPane(): void {
  const state = useUIState.getState();
  const update = resolveDiagnosticsPaneUpdate(state);

  if (update.bottomPaneActiveTab !== state.bottomPaneActiveTab) {
    state.setBottomPaneActiveTab(update.bottomPaneActiveTab);
  }
  state.setIsBottomPaneVisible(update.isBottomPaneVisible);
}

export function resolveGlobalSearchSidebarUpdate(): GlobalSearchSidebarUpdate {
  return {
    activeSidebarView: "search",
    isSidebarVisible: true,
  };
}

export function openGlobalSearchSidebar(): void {
  const state = useUIState.getState();
  const update = resolveGlobalSearchSidebarUpdate();
  state.setActiveView(update.activeSidebarView);
  state.setIsSidebarVisible(update.isSidebarVisible);
}
