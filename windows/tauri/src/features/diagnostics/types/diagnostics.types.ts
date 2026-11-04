import type { LspClientDiagnostic } from "@/core/lsp-diagnostic";

export interface Diagnostic {
  severity: "error" | "warning" | "info";
  filePath: string;
  line: number;
  column: number;
  endLine: number;
  endColumn: number;
  message: string;
  source?: string;
  code?: string;
  owner?: string;
  /** Original Core diagnostic; display fields must never be sent back as LSP data. */
  lspDiagnostic?: LspClientDiagnostic;
}

export interface DiagnosticCodeAction {
  id: string;
  title: string;
  kind?: string;
  isPreferred: boolean;
  disabledReason?: string;
  hasCommand: boolean;
  hasEdit: boolean;
  payload: unknown;
}

export interface ApplyDiagnosticCodeActionResult {
  applied: boolean;
  reason?: string;
}
