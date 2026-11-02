import { describe, expect, test } from "bun:test";
import { getDefaultSettingsSnapshot } from "../config/default-settings";
import { normalizeSettings, normalizeSettingValue } from "./settings-normalization";
import { getUiRootAttributes } from "./ui-preferences";
import { applySettingSideEffect } from "./settings-effects";
import { installHappyDom } from "@/test-utils/happy-dom";
import { filterSettingsCategories } from "./settings-navigation";
import { createTranslator } from "@/i18n/locale";

describe("workbench compact mode", () => {
  test("settings search finds the real control in English and Chinese", () => {
    for (const [language, query] of [
      ["en-US", "Compact mode"],
      ["zh-CN", "紧凑模式"],
    ] as const) {
      expect(
        filterSettingsCategories(query, createTranslator(language)).map(({ id }) => id),
      ).toContain("general");
    }
  });
  test("older and malformed preferences remain regular; a saved choice survives reload", () => {
    const defaults = getDefaultSettingsSnapshot();
    expect(defaults.compactMode).toBe(false);
    for (const value of [undefined, null, "true", 1]) {
      expect(normalizeSettings({ ...defaults, compactMode: value } as never).compactMode).toBe(
        false,
      );
      expect(normalizeSettingValue("compactMode", value as never)).toBe(false);
    }
    const saved = normalizeSettings(JSON.parse(JSON.stringify({ ...defaults, compactMode: true })));
    expect(saved.compactMode).toBe(true);
    expect(getUiRootAttributes(saved)["data-compact-mode"]).toBe("true");
  });

  test("toggling applies immediately and preserves comfortable density, text and panel sizes", () => {
    const restoreDom = installHappyDom();
    try {
      const settings = {
        ...getDefaultSettingsSnapshot(),
        windowChromeDensity: "comfortable" as const,
      };
      const before = structuredClone(settings);
      for (const compactMode of [true, false]) {
        settings.compactMode = compactMode;
        applySettingSideEffect("compactMode", compactMode, () => settings);
        expect(document.documentElement.getAttribute("data-compact-mode")).toBe(
          String(compactMode),
        );
        expect(document.documentElement.getAttribute("data-window-chrome-density")).toBe(
          "comfortable",
        );
        expect({ ...settings, compactMode: false }).toEqual(before);
      }
    } finally {
      restoreDom();
    }
  });
});
