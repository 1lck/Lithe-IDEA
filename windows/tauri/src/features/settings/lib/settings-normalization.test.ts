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
