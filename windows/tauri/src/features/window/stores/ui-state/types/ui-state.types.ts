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
  // Maven task output is independent from the right-side Maven navigation tool window.
  | "maven"
  | "gitLog";

export interface QuickEditSelection {
  text: string;
  start: number;
  end: number;
  cursorPosition: { x: number; y: number };
}
