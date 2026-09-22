import { describe, expect, test } from "bun:test";
import { normalizeRunMarkers, runMarkerForLine, runMarkerIcon, type RunMarker } from "./run-markers";

function marker(overrides: Partial<RunMarker>): RunMarker {
  return { id: "m", line: 1, endLine: 1, kind: "main", label: "App.main()", status: "none", ...overrides };
}

describe("editor Run markers", () => {
  test("choose IDEA's icon from kind and last outcome", () => {
    expect(runMarkerIcon(marker({}))).toBe("run");
    expect(runMarkerIcon(marker({ kind: "testClass" }))).toBe("run-all");
    expect(runMarkerIcon(marker({ kind: "testMethod", status: "passed" }))).toBe("passed");
    expect(runMarkerIcon(marker({ kind: "testClass", status: "failed" }))).toBe("failed");
    expect(runMarkerIcon(marker({ kind: "testMethod", status: "skipped" }))).toBe("run");
  });

  test("drop malformed or out-of-document markers and keep one per line", () => {
    const markers = normalizeRunMarkers([
      { id: "a", line: 2, endLine: 9, kind: "testClass", label: "OrderTest", status: "failed" },
      { id: "b", line: 2, endLine: 2, kind: "testMethod", label: "dup", status: "none" },
      { id: "c", line: 40, endLine: 40, kind: "main", label: "late", status: "none" },
      { id: "d", line: 3, kind: "unknown", label: "x" },
      { id: "e", line: 4, endLine: 99, kind: "testMethod", label: "clamped", status: "weird" },
    ], 10);

    expect(markers.map(item => item.id)).toEqual(["a", "e"]);
    expect(markers[1]).toMatchObject({ endLine: 10, status: "none" });
    expect(normalizeRunMarkers({ markers: [] }, 10)).toEqual([]);
  });

  test("pick the innermost test declaration, then the file's main", () => {
    const markers = [
      marker({ id: "main", line: 3, endLine: 3 }),
      marker({ id: "class", line: 6, endLine: 15, kind: "testClass", label: "OrderTest" }),
      marker({ id: "method", line: 8, endLine: 8, kind: "testMethod", label: "OrderTest.creates" }),
      marker({ id: "nested", line: 11, endLine: 14, kind: "testClass", label: "Refunds" }),
    ];
    expect(runMarkerForLine(markers, 8)?.id).toBe("method");
    expect(runMarkerForLine(markers, 12)?.id).toBe("nested");
    expect(runMarkerForLine(markers, 15)?.id).toBe("class");
    expect(runMarkerForLine(markers, 1)?.id).toBe("main");
    expect(runMarkerForLine([], 1)).toBeUndefined();
  });
});
