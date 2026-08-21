import { describe, expect, test } from "bun:test";
import { getDefaultSettingsSnapshot } from "@/features/settings/config/default-settings";
import {
  normalizeSettings,
  normalizeSettingValue,
} from "@/features/settings/lib/settings-normalization";

describe("default settings", () => {
  test("enables auto-save unless the user turns it off", () => {
    expect(getDefaultSettingsSnapshot().autoSave).toBe(true);
  });
});

describe("JDTLS JDK setting normalization", () => {
  test("defaults to automatic discovery", () => {
    expect(getDefaultSettingsSnapshot().jdtlsJavaHomePath).toBe("");
  });

  test("trims a manually selected JDK home", () => {
    expect(normalizeSettingValue("jdtlsJavaHomePath", "  C:/Java/jdk-21  ")).toBe(
      "C:/Java/jdk-21",
    );
  });

  test("discards a persisted non-string JDK home", () => {
    const settings = getDefaultSettingsSnapshot();
    (settings as unknown as { jdtlsJavaHomePath: unknown }).jdtlsJavaHomePath = 21;

    expect(normalizeSettings(settings).jdtlsJavaHomePath).toBe("");
  });
});

describe("IDEA file icon theme normalization", () => {
  test("uses IDEA Icons for new settings", () => {
    expect(getDefaultSettingsSnapshot().iconTheme).toBe("idea-icons");
  });

  test("migrates current and legacy Lithe icon theme ids", () => {
    for (const iconTheme of [
      "lithe-icons",
      "lithe-icons-dimmed",
      "lithe-icons-light",
      "lithe-file-icons",
      "lithe-file-icons-dark",
      "lithe-file-icons-light",
    ]) {
      expect(normalizeSettingValue("iconTheme", iconTheme)).toBe("idea-icons");
    }
  });
});

describe("Windows New UI defaults", () => {
  test("uses Chinese and the native CJK UI typography for new settings", () => {
    const settings = getDefaultSettingsSnapshot();

    expect(settings.displayLanguage).toBe("zh-CN");
    expect(settings.uiFontFamily).toBe("Microsoft YaHei UI");
    expect(settings.uiFontSize).toBe(13);
  });

  test("migrates the previous bundled UI typography as a pair", () => {
    const settings = getDefaultSettingsSnapshot();
    settings.uiFontFamily = "Geist Sans";
    settings.uiFontSize = 15;

    const normalized = normalizeSettings(settings);

    expect(normalized.uiFontFamily).toBe("Microsoft YaHei UI");
    expect(normalized.uiFontSize).toBe(13);
  });

  test("preserves an explicitly customized typography pair", () => {
    const settings = getDefaultSettingsSnapshot();
    settings.uiFontFamily = "Geist Sans";
    settings.uiFontSize = 14;

    const normalized = normalizeSettings(settings);

    expect(normalized.uiFontFamily).toBe("Geist Sans");
    expect(normalized.uiFontSize).toBe(14);
  });
});
