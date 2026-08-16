import { describe, expect, test } from "bun:test";
import { SETTINGS_TAB_ITEMS } from "../components/settings-vertical-tabs";
import { filterVisibleSettingsTabs } from "./settings-tab-visibility";

describe("supported Windows settings tabs", () => {
  test("excludes account and unavailable feature settings", () => {
    const visibleTabs = filterVisibleSettingsTabs(SETTINGS_TAB_ITEMS, {
      canShowCollaborationSettings: false,
      canShowEnterpriseSettings: false,
      matchingTabs: null,
    });

    expect(visibleTabs.map((tab) => tab.id)).toEqual([
      "general",
      "appearance",
      "editor",
      "file-explorer",
      "git",
      "terminal",
      "keyboard",
      "advanced",
    ]);
  });
});
