// Pure rules for editor Run markers shared by editor hosts. Marker facts come
// from the host (JDT through Rust Core, or a plugin's provider validated by
// Rust Core); this module only picks icons and the marker a caret line refers to.

/** `run` is a plugin's runnable unit, such as one request of an `.http` file. */
export type RunMarkerKind = "main" | "run" | "testClass" | "testMethod";
export type RunMarkerStatus = "none" | "passed" | "failed" | "skipped";

/** One gutter marker as the host sends it, with one-based lines. */
export interface RunMarker {
  id: string;
  line: number;
  /** Last line of the declaration: body end for tests, name line for `main`. */
  endLine: number;
  kind: RunMarkerKind;
  /** Menu target such as `App.main()`, `OrderTest`, or `OrderTest.creates`. */
  label: string;
  status: RunMarkerStatus;
}

export type RunMarkerIcon = "run" | "run-all" | "passed" | "failed";

/** IDEA's test-state icon: Run, Run-all for classes, or the last outcome. */
export function runMarkerIcon(marker: Pick<RunMarker, "kind" | "status">): RunMarkerIcon {
  if (marker.status === "passed") return "passed";
  if (marker.status === "failed") return "failed";
  return marker.kind === "testClass" ? "run-all" : "run";
}

/** Keeps only well-formed markers inside the document, one per line. */
export function normalizeRunMarkers(value: unknown, lineCount: number): RunMarker[] {
  if (!Array.isArray(value)) return [];
  const seen = new Set<number>();
  const markers: RunMarker[] = [];
  for (const candidate of value as Partial<RunMarker>[]) {
    if (!candidate || typeof candidate.id !== "string" || typeof candidate.label !== "string" ||
        !Number.isInteger(candidate.line) || candidate.line! < 1 || candidate.line! > lineCount ||
        !["main", "run", "testClass", "testMethod"].includes(candidate.kind as string)) continue;
    const endLine = Number.isInteger(candidate.endLine) && candidate.endLine! >= candidate.line!
      ? Math.min(candidate.endLine!, lineCount) : candidate.line!;
    const status = ["passed", "failed", "skipped"].includes(candidate.status as string)
      ? candidate.status as RunMarkerStatus : "none";
    if (seen.has(candidate.line!)) continue;
    seen.add(candidate.line!);
    markers.push({ id: candidate.id, line: candidate.line!, endLine, kind: candidate.kind!, label: candidate.label, status });
  }
  return markers;
}

/** Plugin marker kinds (`runMarkers` 1) in the editor's marker vocabulary. */
const PLUGIN_MARKER_KINDS: Record<string, RunMarkerKind> = { run: "run", test: "testMethod", testSuite: "testClass" };

/**
 * Markers of a `plugins.declarative.decodeRunMarkers` answer. Plugin markers
 * carry no test outcome, and their `title` is the menu target.
 */
export function pluginRunMarkers(value: unknown, lineCount: number): RunMarker[] {
  if (!Array.isArray(value)) return [];
  return normalizeRunMarkers(value.map(marker => marker && typeof marker === "object" ? {
    id: marker.id, line: marker.line, endLine: marker.endLine,
    kind: PLUGIN_MARKER_KINDS[marker.kind], label: marker.title, status: "none",
  } : undefined), lineCount);
}

/**
 * The marker a caret line refers to, following IDEA: the innermost test
 * method or class whose declaration contains the line, otherwise the `main`
 * on that line, otherwise the file's first `main`.
 */
export function runMarkerForLine(markers: readonly RunMarker[], line: number): RunMarker | undefined {
  let enclosing: RunMarker | undefined;
  for (const marker of markers) {
    if (marker.kind === "main" || line < marker.line || line > marker.endLine) continue;
    if (!enclosing || marker.line > enclosing.line ||
        (marker.line === enclosing.line && marker.kind === "testMethod")) enclosing = marker;
  }
  if (enclosing) return enclosing;
  const mains = markers.filter(marker => marker.kind === "main");
  return mains.find(marker => marker.line === line) ?? mains[0];
}
