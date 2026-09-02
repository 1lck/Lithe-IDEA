export type SettingsTab =
  | "general"
  | "editor"
  | "git"
  | "appearance"
  | "ai"
  | "keyboard"
  | "language"
  | "logs"
  | "advanced"
  | "terminal"
  | "file-explorer";

export type BottomPaneTab =
  | "terminal"
  | "debugger"
  | "diagnostics"
  | "references"
  | "buffers"
  | "run"
  // Kept so persisted preview sessions can migrate the former bottom Maven pane.
  | "maven"
  | "gitLog";

export interface QuickEditSelection {
  text: string;
  start: number;
  end: number;
  cursorPosition: { x: number; y: number };
}
