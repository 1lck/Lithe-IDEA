import { describe, expect, test } from "bun:test";
import { getProjectGradientColorIndex, PROJECT_GRADIENT_COLOR_COUNT } from "./project-gradient";

describe("getProjectGradientColorIndex", () => {
  test("returns a 1-based index into the nine Islands project colors", () => {
    for (const path of ["C:/work/lithe", "/home/me/app", "D:\\a", ""]) {
      const index = getProjectGradientColorIndex(path);
      expect(index).toBeGreaterThanOrEqual(1);
      expect(index).toBeLessThanOrEqual(PROJECT_GRADIENT_COLOR_COUNT);
    }
  });

  test("matches the macOS palette index for the same path, shifted to 1-based", () => {
    // FNV-1a 64 of "/projects/alpha" is 0x875b61f8ea0be217; mod 9 gives macOS index 3.
    expect(getProjectGradientColorIndex("/projects/alpha")).toBe(4);
  });

  test("keeps one color for the same Windows project however its path is spelled", () => {
    const index = getProjectGradientColorIndex("D:/project/Lithe-IDEA");
    expect(getProjectGradientColorIndex("D:\\project\\Lithe-IDEA")).toBe(index);
    expect(getProjectGradientColorIndex("d:/project/lithe-idea/")).toBe(index);
  });
});
