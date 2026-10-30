import { describe, expect, test } from "bun:test";
import { getLitheDefaultTheme } from "@/extensions/themes/default-theme";
import { nativeWindowBackground } from "./native-window-background";

describe("nativeWindowBackground", () => {
  test("normalizes the hex forms themes use to opaque #rrggbb", () => {
    expect(nativeWindowBackground("#191A1C")).toBe("#191a1c");
    expect(nativeWindowBackground(" #fff ")).toBe("#ffffff");
    expect(nativeWindowBackground("#eff1f580")).toBe("#eff1f5");
  });

  test("converts rgb() and rgba() colours", () => {
    expect(nativeWindowBackground("rgb(25, 26, 28)")).toBe("#191a1c");
    expect(nativeWindowBackground("rgba(255 255 255 / 0.5)")).toBe("#ffffff");
  });

  test("leaves formats it cannot resolve to the host", () => {
    for (const value of [undefined, "", "var(--surface)", "oklch(0.2 0.01 260)", "#12345"]) {
      expect(nativeWindowBackground(value)).toBeNull();
    }
  });

  test("resolves both bundled Lithe themes", () => {
    for (const type of ["dark", "light"] as const) {
      const background = getLitheDefaultTheme(type).definition.cssVariables["--background"];
      expect(nativeWindowBackground(background)).toMatch(/^#[0-9a-f]{6}$/);
    }
  });
});
