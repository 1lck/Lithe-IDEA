import { describe, expect, test } from "bun:test";
import { MonacoThemeDefinitionCache } from "./theme-definition-cache";

describe("MonacoThemeDefinitionCache", () => {
  test("an unchanged theme is defined once so editor mounts do not refresh Monaco's global theme", () => {
    const cache = new MonacoThemeDefinitionCache();

    expect(cache.needsDefinition("lithe-dark", { colors: { background: "#101010" } })).toBe(true);
    expect(cache.needsDefinition("lithe-dark", { colors: { background: "#101010" } })).toBe(false);
  });

  test("changed colors and other theme names still reach Monaco", () => {
    const cache = new MonacoThemeDefinitionCache();
    cache.needsDefinition("lithe-dark", { colors: { background: "#101010" } });

    expect(cache.needsDefinition("lithe-dark", { colors: { background: "#202020" } })).toBe(true);
    expect(cache.needsDefinition("lithe-dark-italic-comments", { colors: { background: "#202020" } })).toBe(true);
  });
});
