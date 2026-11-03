import type { editor } from "monaco-editor";
import type { Diagnostic } from "@/features/diagnostics/types/diagnostics.types";

// Monaco widens empty markers and reduces severities. Keep all originals when
// that projection is ambiguous, including distinct owners of the same marker.
export function diagnosticsForCodeActionMarker(diagnostics: Diagnostic[], marker: editor.IMarkerData): Diagnostic[] {
  return diagnostics.filter((entry) =>
    (entry.severity === "error" ? 8 : entry.severity === "warning" ? 4 : 2) === marker.severity &&
    entry.line + 1 === marker.startLineNumber && entry.column + 1 === marker.startColumn &&
    entry.endLine + 1 === marker.endLineNumber &&
    Math.max(entry.endColumn + 1, entry.column + 2) === marker.endColumn &&
    entry.message === marker.message && entry.source === marker.source &&
    entry.code === (typeof marker.code === "string" ? marker.code : marker.code?.value));
}
