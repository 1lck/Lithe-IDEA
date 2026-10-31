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
  | `plugin-native:${string}`
  | `plugin-web:${string}`
  | "terminal"
  | "debugger"
  | "diagnostics"
  | "references"
  | "buffers"
  | "run"
  // Maven task output is independent from the right-side Maven navigation tool window.
  | "maven"
  | "gitLog"
  | "springEndpoints";

export interface QuickEditSelection {
  text: string;
  start: number;
  end: number;
  cursorPosition: { x: number; y: number };
}
