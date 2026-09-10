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
  | "lsp";

export interface RunActionItem {
  id: string;
  name: string;
  command?: string;
  description?: string;
  source: RunActionSource;
  sourceLabel: string;
  workingDirectory?: string;
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
