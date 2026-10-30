export type SettingsTab =
  | "run"
  | "project"
  | "mcp"
  | "general"
  | "editor"
  | "git"
  | "appearance"
  | "ai"
  | "agents"
  | "hooks"
  | "ai-commit"
  | "keyboard"
  | "language"
  | "logs"
  | "advanced"
  | "terminal"
  | "maven"
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
  | "build"
  | "gitLog"
  | "springEndpoints";

export interface QuickEditSelection {
  text: string;
  start: number;
  end: number;
  cursorPosition: { x: number; y: number };
}
