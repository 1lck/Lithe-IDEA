import { describe, expect, test } from "bun:test";
import { normalizeJavaImplementationMarkers } from "./java-navigation-models";

describe("normalizeJavaImplementationMarkers", () => {
  test("keeps valid markers in source order", () => {
    expect(
      normalizeJavaImplementationMarkers([
        {
          line: 9,
          utf16Column: 2,
          implementationCount: 1,
          direction: "up",
          relation: "inheritance",
        },
        {
          line: 3,
          utf16Column: 4,
          implementationCount: 2,
          direction: "down",
          relation: "interface",
        },
      ]).map((marker) => marker.line),
    ).toEqual([3, 9]);
  });

  test("rejects incomplete boundary values", () => {
    expect(normalizeJavaImplementationMarkers([{ line: 1 }, null, "marker"])).toEqual([]);
  });
});
