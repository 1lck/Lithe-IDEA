import { describe, expect, test } from "bun:test";
import { shouldShowProjectSwitcher } from "./project-switcher";

describe("project switcher visibility", () => {
  test("hides the activity-bar switcher when projects open in new windows", () => {
    expect(shouldShowProjectSwitcher(true, true)).toBe(false);
  });

  test("shows the activity-bar switcher when in-window switching is enabled", () => {
    expect(shouldShowProjectSwitcher(true, false)).toBe(true);
  });

  test("respects the user's project switcher visibility setting", () => {
    expect(shouldShowProjectSwitcher(false, false)).toBe(false);
    expect(shouldShowProjectSwitcher(false, true)).toBe(false);
  });
});
