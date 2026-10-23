import { describe, expect, test } from "bun:test";
import {
  createTranslator,
  DISPLAY_LANGUAGES,
  getLocaleCatalog,
  LANGUAGE_OPTIONS,
  normalizeDisplayLanguage,
} from "./locale";
import { DEFAULT_DISPLAY_LANGUAGE, DEFAULT_LOCALE, sharedCatalogs } from "./shared.generated";
import { defaultSettings } from "@/features/settings/config/default-settings";
import {
  normalizeSettings,
  normalizeSettingValue,
} from "@/features/settings/lib/settings-normalization";

describe("Shared built-in translations", () => {
  test("language options, persistence validation and existing defaults use the registry", () => {
    expect(LANGUAGE_OPTIONS.map((option) => option.value)).toEqual([...DISPLAY_LANGUAGES]);
    expect(DEFAULT_LOCALE).toBe("en-US");
    expect(DEFAULT_DISPLAY_LANGUAGE).toBe("zh-CN");
    expect(defaultSettings.displayLanguage).toBe("zh-CN");
    for (const language of DISPLAY_LANGUAGES) {
      expect(normalizeDisplayLanguage(language)).toBe(language);
      expect(normalizeSettingValue("displayLanguage", language)).toBe(language);
    }
    for (const invalid of [undefined, null, "", "unknown", "__proto__", 42]) {
      expect(normalizeDisplayLanguage(invalid)).toBe(DEFAULT_DISPLAY_LANGUAGE);
      expect(
        normalizeSettings({ ...defaultSettings, displayLanguage: invalid as never })
          .displayLanguage,
      ).toBe(DEFAULT_DISPLAY_LANGUAGE);
    }
  });

  test("shared resources resolve through the existing API and retain unmigrated entries", () => {
    for (const language of DISPLAY_LANGUAGES) {
      const t = createTranslator(language);
      for (const [key, value] of Object.entries(sharedCatalogs[language])) {
        expect(t(key)).toBe(value);
        expect(getLocaleCatalog(language)[key]).toBe(value);
      }
    }
    expect(createTranslator("en-US")("ui.save")).toBe("Save");
    expect(createTranslator("zh-CN")("ui.save")).toBe("保存");
    expect(createTranslator("zh-CN")("quickOpen.filesCount", { count: 0 })).toBe("0 个文件");
    expect(createTranslator("zh-CN")("workbench.terminal")).toBe("终端");
    expect(createTranslator("en-US")("files.reveal")).toBe("Reveal in File Explorer");
  });

  test("interpolated values stay literal and unknown keys never read object prototypes", () => {
    const t = createTranslator("en-US");
    expect(t("footer.memoryUsage", { total: "{used}", used: "100% 中文" })).toBe(
      "Total {used} · Lithe 100% 中文",
    );
    expect(t("quickOpen.filesCount")).toBe("{count} files");
    for (const key of ["untranslated.fixture", "constructor", "toString", "__proto__"])
      expect(t(key)).toBe(key);
    expect(t("quickOpen.filesCount", Object.create({ count: 3 }))).toBe("{count} files");
  });
});
