/** JSON shape of Core's LspClientDiagnostic; positions are zero-based UTF-16. */
export interface LspClientDiagnostic {
  range: LspDiagnosticRange;
  severity: number | null;
  message: string;
  source: string | null;
  code: string | null;
  tags: number[];
  relatedInformation: {
    location: { uri: string; range: LspDiagnosticRange };
    message: string;
  }[];
}

export interface LspDiagnosticRange {
  start: { line: number; utf16Column: number };
  end: { line: number; utf16Column: number };
}
