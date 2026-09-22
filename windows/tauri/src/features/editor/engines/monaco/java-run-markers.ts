import type * as Monaco from "monaco-editor";
import type { JavaRunMarker } from "@/features/run/services/java-run-markers";

export const JAVA_RUN_GLYPH_CLASS = "lithe-java-run-glyph";

/**
 * Monaco's center glyph lane. Implementation markers use the left (up) and
 * right (down) lanes, so a test method that also overrides a method keeps
 * both icons visible, matching IDEA's gutter icon row.
 */
const RUN_GLYPH_LANE = 2;

/** IDEA test-state icon for a marker: Run, Run-all, passed, or failed. */
export function runGlyphVariant(marker: JavaRunMarker): "run" | "run-all" | "passed" | "failed" {
  if (marker.status === "passed") return "passed";
  if (marker.status === "failed") return "failed";
  return marker.kind === "testClass" ? "run-all" : "run";
}

export function runMarkerDecorations(
  markers: readonly JavaRunMarker[],
  hoverText: (marker: JavaRunMarker) => string,
): Monaco.editor.IModelDeltaDecoration[] {
  return markers.map((marker) => ({
    range: {
      startLineNumber: marker.line + 1,
      startColumn: 1,
      endLineNumber: marker.line + 1,
      endColumn: 1,
    },
    options: {
      description: "Java run marker",
      glyphMarginClassName: `${JAVA_RUN_GLYPH_CLASS} ${JAVA_RUN_GLYPH_CLASS}-${runGlyphVariant(marker)}`,
      glyphMargin: { position: RUN_GLYPH_LANE },
      glyphMarginHoverMessage: { value: hoverText(marker) },
      stickiness: 1,
    },
  }));
}

/** The marker drawn on a one-based editor line, preferring the broadest target. */
export function runMarkerAtLine(
  markers: readonly JavaRunMarker[],
  lineNumber: number,
): JavaRunMarker | null {
  return markers.find((marker) => marker.line + 1 === lineNumber) ?? null;
}
