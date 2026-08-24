import { describe, expect, test } from "bun:test";
import {
  implementationGlyphVariantClass,
  implementationMarkerAtLine,
  implementationMarkerDecorations,
  implementationMarkersForBuffer,
  javaMarkerRefreshRevision,
  javaMarkerRetryDelay,
  JAVA_IMPLEMENTATION_GLYPH_CLASS,
} from "./java-implementation-markers";

const interfaceDownMarker = {
  line: 6,
  utf16Column: 17,
  implementationCount: 2,
  direction: "down" as const,
  relation: "interface" as const,
};

const inheritanceUpMarker = {
  line: 10,
  utf16Column: 4,
  implementationCount: 0,
  direction: "up" as const,
  relation: "inheritance" as const,
};

describe("Java implementation gutter projection", () => {
  test("maps zero-based Core lines to one-based Monaco glyph decorations", () => {
    expect(implementationMarkerDecorations([interfaceDownMarker])).toEqual([
      expect.objectContaining({
        range: expect.objectContaining({ startLineNumber: 7, endLineNumber: 7 }),
        options: expect.objectContaining({
          glyphMarginClassName: `${JAVA_IMPLEMENTATION_GLYPH_CLASS} ${JAVA_IMPLEMENTATION_GLYPH_CLASS}-interface-down`,
        }),
      }),
    ]);
  });

  test("encodes relation and direction into the variant class", () => {
    expect(implementationGlyphVariantClass(interfaceDownMarker)).toBe(
      `${JAVA_IMPLEMENTATION_GLYPH_CLASS}-interface-down`,
    );
    expect(implementationGlyphVariantClass(inheritanceUpMarker)).toBe(
      `${JAVA_IMPLEMENTATION_GLYPH_CLASS}-inheritance-up`,
    );
  });

  test("routes a gutter click back to the marker UTF-16 position", () => {
    const markers = [interfaceDownMarker];
    expect(implementationMarkerAtLine(markers, 7)).toEqual(interfaceDownMarker);
    expect(implementationMarkerAtLine(markers, 8)).toBeNull();
  });

  test("does not project markers owned by the previous buffer", () => {
    const markers = [interfaceDownMarker];
    expect(implementationMarkersForBuffer(markers, "buffer-a", "buffer-b")).toEqual([]);
    expect(implementationMarkersForBuffer(markers, "buffer-b", "buffer-b")).toBe(markers);
  });

  test("changes the refresh revision for readiness and document lifecycle updates", () => {
    const connecting = javaMarkerRefreshRevision({
      status: "connecting",
      activeWorkspaces: [],
      documentRevision: 0,
    });
    const connected = javaMarkerRefreshRevision({
      status: "connected",
      activeWorkspaces: ["C:/workspace"],
      supportedLanguages: ["Java"],
      documentRevision: 0,
    });
    const documentOpened = javaMarkerRefreshRevision({
      status: "connected",
      activeWorkspaces: ["C:/workspace"],
      supportedLanguages: ["Java"],
      documentRevision: 1,
    });

    expect(connected).not.toBe(connecting);
    expect(documentOpened).not.toBe(connected);
  });

  test("bounds transient JDTLS startup retries", () => {
    expect([0, 1, 2, 3, 4].map(javaMarkerRetryDelay)).toEqual([
      1_500,
      3_000,
      6_000,
      12_000,
      null,
    ]);
  });
});
