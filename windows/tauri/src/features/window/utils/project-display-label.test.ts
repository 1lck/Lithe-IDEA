import { describe, expect, test } from "bun:test";
import {
  formatProjectDisplayLabel,
  getProjectDisplayLabel,
} from "./project-display-label";

describe("project display label", () => {
  test("returns folder name when no alias is set", () => {
    expect(getProjectDisplayLabel({ name: "Lithe", displayAlias: undefined })).toBe("Lithe");
    expect(formatProjectDisplayLabel("Lithe", "")).toBe("Lithe");
    expect(formatProjectDisplayLabel("Lithe", "   ")).toBe("Lithe");
  });

  test("appends trimmed alias after the folder name", () => {
    expect(getProjectDisplayLabel({ name: "Lithe", displayAlias: "work copy" })).toBe(
      "Lithe (work copy)",
    );
    expect(formatProjectDisplayLabel("Lithe", "  work copy  ")).toBe("Lithe (work copy)");
  });
});
