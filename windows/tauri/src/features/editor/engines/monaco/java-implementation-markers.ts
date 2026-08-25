import type * as Monaco from "monaco-editor";
import type { JavaImplementationMarker } from "@/features/editor/lsp/java-navigation-models";

export const JAVA_IMPLEMENTATION_GLYPH_CLASS = "lithe-java-implementation-glyph";

export interface JavaImplementationDecorationTarget {
  line: number;
  utf16Column: number;
  implementationCount: number;
  direction: "up" | "down";
}

interface JavaMarkerRefreshStatus {
  status: string;
  activeWorkspaces: readonly string[];
  supportedLanguages?: readonly string[];
  documentRevision: number;
}

/**
 * Produces the React dependency for marker refreshes. Reading this snapshot
 * during render covers both server transitions and an editor mounted after
 * JDTLS already became ready, without relying on a lossy effect subscription.
 */
export function javaMarkerRefreshRevision(status: JavaMarkerRefreshStatus): string {
  return [
    status.status,
    status.activeWorkspaces.join("|"),
    status.supportedLanguages?.join("|") ?? "",
    status.documentRevision,
  ].join(":");
}

const JAVA_MARKER_RETRY_DELAYS_MS = [1_500, 3_000, 6_000, 12_000] as const;

/** Returns the next bounded startup retry delay, or `null` once exhausted. */
export function javaMarkerRetryDelay(attempt: number): number | null {
  return JAVA_MARKER_RETRY_DELAYS_MS[attempt] ?? null;
}

/**
 * Encodes both navigation axes into the glyph class so the stylesheet can pick
 * the matching IDEA gutter icon:
 * - `relation`: `interface` (green I) vs `inheritance` (blue O)
 * - `direction`: `down` toward implementations vs `up` toward the declaring type
 */
export function implementationGlyphVariantClass(marker: JavaImplementationMarker): string {
  return `${JAVA_IMPLEMENTATION_GLYPH_CLASS}-${marker.relation}-${marker.direction}`;
}

export function implementationMarkersForBuffer(
  markers: JavaImplementationMarker[],
  ownerBufferId: string | null,
  currentBufferId: string | undefined,
): JavaImplementationMarker[] {
  return ownerBufferId !== null && ownerBufferId === currentBufferId ? markers : [];
}

export function implementationMarkerDecorations(
  markers: readonly JavaImplementationMarker[],
): Monaco.editor.IModelDeltaDecoration[] {
  return markers.map((marker) => ({
    range: {
      startLineNumber: marker.line + 1,
      startColumn: 1,
      endLineNumber: marker.line + 1,
      endColumn: 1,
    },
    options: {
      description: "Java implementation marker",
      glyphMarginClassName: `${JAVA_IMPLEMENTATION_GLYPH_CLASS} ${implementationGlyphVariantClass(marker)}`,
      glyphMargin: {
        // Monaco uses lane 1 for left and lane 3 for right. IDEA places the
        // upward relation on the left and the downward relation on the right.
        position: marker.direction === "up" ? 1 : 3,
      },
      glyphMarginHoverMessage: {
        value: implementationMarkerHoverText(marker),
      },
      stickiness: 1,
    },
  }));
}

/** Matches IDEA's gutter tooltips, which name the relationship being followed. */
function implementationMarkerHoverText(marker: JavaImplementationMarker): string {
  if (marker.implementationCount > 1) {
    return marker.direction === "down"
      ? `Show ${marker.implementationCount} implementations`
      : `Show ${marker.implementationCount} declarations`;
  }
  if (marker.direction === "down") {
    return marker.relation === "inheritance" ? "Go to overriding method" : "Go to implementation";
  }
  return marker.relation === "inheritance"
    ? "Go to overridden method"
    : "Go to implemented method";
}

export function implementationMarkerAtLine(
  markers: readonly JavaImplementationMarker[],
  lineNumber: number,
  glyphMarginLane?: number,
): JavaImplementationDecorationTarget | null {
  const direction = glyphMarginLane === 1 ? "up" : glyphMarginLane === 3 ? "down" : null;
  const marker = markers.find(
    (candidate) =>
      candidate.line + 1 === lineNumber && (direction === null || candidate.direction === direction),
  );
  return marker ?? null;
}
