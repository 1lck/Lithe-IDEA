import { describe, expect, test } from "bun:test";
import type { JavaRunMarker } from "@/features/run/services/java-run-markers";
import {
  JAVA_RUN_GLYPH_CLASS,
  runGlyphVariant,
  runMarkerAtLine,
  runMarkerDecorations,
} from "./java-run-markers";

function marker(overrides: Partial<JavaRunMarker>): JavaRunMarker {
  return { line: 4, endLine: 4, kind: "main", label: "App.main()", status: "none", ...overrides };
}

describe("Java Run marker decorations", () => {
  test("chooses IDEA's icon from the marker kind and last outcome", () => {
    expect(runGlyphVariant(marker({}))).toBe("run");
    expect(runGlyphVariant(marker({ kind: "testClass" }))).toBe("run-all");
    expect(runGlyphVariant(marker({ kind: "testMethod", status: "passed" }))).toBe("passed");
    expect(runGlyphVariant(marker({ kind: "testClass", status: "failed" }))).toBe("failed");
    expect(runGlyphVariant(marker({ kind: "testMethod", status: "skipped" }))).toBe("run");
  });

  test("draws in the center glyph lane on the one-based declaration line", () => {
    const [decoration] = runMarkerDecorations([marker({})], (item) => `Run '${item.label}'`);

    expect(decoration?.range.startLineNumber).toBe(5);
    expect(decoration?.options.glyphMarginClassName).toBe(
      `${JAVA_RUN_GLYPH_CLASS} ${JAVA_RUN_GLYPH_CLASS}-run`,
    );
    expect(decoration?.options.glyphMargin).toEqual({ position: 2 });
    expect(decoration?.options.glyphMarginHoverMessage).toEqual({ value: "Run 'App.main()'" });
  });

  test("finds the marker drawn on a clicked line", () => {
    const markers = [marker({ line: 4 }), marker({ line: 9, label: "Other.main()" })];

    expect(runMarkerAtLine(markers, 10)?.label).toBe("Other.main()");
    expect(runMarkerAtLine(markers, 6)).toBeNull();
  });
});
