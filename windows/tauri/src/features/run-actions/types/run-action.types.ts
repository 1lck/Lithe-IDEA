import type { CodeLensItem } from "@/features/editor/lsp/use-code-lens";

export type RunActionSource =
  | "custom"
  | "maven"
  | "package"
  | "cargo"
  | "make"
  | "just"
  | "go"
  | "python"
  | "extension"
  | "lsp"
  | "declarative";

export interface RunActionItem {
  /** Owning declarative plugin, for `source: "declarative"` items. */
  declarativeOwner?: { pluginId: string; languageId: string };
  /** Route this declarative action through the plugin's test template. */
  declarativeTest?: boolean;
  declarativeTestScope?: import("@/features/plugins/declarative-plugin-launch").DeclarativeTestScope;
  declarativeContext?: import("@/features/plugins/declarative-plugin-launch").DeclarativeExecutionContext;
  /** Local revocation guard captured at discovery; never sent over IPC. */
  declarativeValidate?: () => void;
  /** Explicit semantic identity from the owning test entry, never inferred
   * from a localized label or shell command. Build-tool actions keep their
   * separate owner unless they explicitly describe the same framework and scope. */
  testTarget?: {
    languageId: string;
    frameworkId?: string;
    scope: import("@/features/plugins/declarative-plugin-launch").DeclarativeTestScope;
  };
  id: string;
  name: string;
  command?: string;
  description?: string;
  source: RunActionSource;
  sourceLabel: string;
  workingDirectory?: string;
  extensionId?: string;
  pluginCommand?: { executable: string; arguments: string[] };
  codeLens?: CodeLensItem;
  mavenTest?: {
    filePath: string;
    method?: string;
  };
}

export interface CustomRunAction {
  id: string;
  name: string;
  command: string;
  workspacePath?: string;
  workingDirectory?: string;
}

export interface RunActionDraft {
  id?: string;
  name: string;
  command: string;
  workingDirectory: string;
}
