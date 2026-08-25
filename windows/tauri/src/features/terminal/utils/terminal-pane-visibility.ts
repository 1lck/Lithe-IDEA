interface TerminalPaneVisibilityState {
  bottomPaneActiveTab: string;
  isBottomPaneVisible: boolean;
  previousTerminalCount: number;
  terminalCount: number;
}

interface NewTerminalEntryActions {
  createTerminal: () => void;
  setBottomPaneActiveTab: (tab: "terminal") => void;
  setIsBottomPaneVisible: (visible: true) => void;
}

export function shouldAutoHideTerminalPane({
  bottomPaneActiveTab,
  isBottomPaneVisible,
  previousTerminalCount,
  terminalCount,
}: TerminalPaneVisibilityState): boolean {
  return (
    isBottomPaneVisible &&
    bottomPaneActiveTab === "terminal" &&
    previousTerminalCount > 0 &&
    terminalCount === 0
  );
}

export function openNewTerminalFromGlobalEntry({
  createTerminal,
  setBottomPaneActiveTab,
  setIsBottomPaneVisible,
}: NewTerminalEntryActions): void {
  setBottomPaneActiveTab("terminal");
  setIsBottomPaneVisible(true);
  createTerminal();
}
