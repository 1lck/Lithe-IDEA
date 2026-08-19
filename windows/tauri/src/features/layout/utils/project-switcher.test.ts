import { describe, expect, test } from "bun:test";
import { defaultSettings } from "@/features/settings/config/default-settings";

describe("activity rail project switcher", () => {
  test("does not expose the removed project switcher setting", () => {
    expect("showActivityRailProjectSwitcher" in defaultSettings).toBe(false);
  });
});
