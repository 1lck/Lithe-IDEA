import { describe, expect, test } from "bun:test";
import { getDefaultSettingsSnapshot } from "@/features/settings/config/default-settings";
import {
  normalizeSettings,
  normalizeSettingValue,
} from "@/features/settings/lib/settings-normalization";

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
