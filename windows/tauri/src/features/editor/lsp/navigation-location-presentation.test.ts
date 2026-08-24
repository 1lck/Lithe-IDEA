import { describe, expect, test } from "bun:test";
import { navigationLocationPresentation } from "./navigation-location-presentation";

describe("LSP navigation location presentation", () => {
  test("opens one implementation directly and presents multiple implementations as a list", () => {
    expect(navigationLocationPresentation(0)).toBe("empty");
    expect(navigationLocationPresentation(1)).toBe("direct");
    expect(navigationLocationPresentation(2, true)).toBe("list");
  });

  test("keeps existing navigation commands on their first result by default", () => {
    expect(navigationLocationPresentation(2)).toBe("direct");
  });
});
