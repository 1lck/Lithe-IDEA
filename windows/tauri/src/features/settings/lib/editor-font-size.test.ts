import { expect, test } from "bun:test";
import { defaultSettings } from "../config/default-settings";
import { normalizeEditorFontSize } from "./editor-font-size";
import { normalizeSettingValue, normalizeSettings } from "./settings-normalization";

test("editor sizes accept the supported range and reject non-finite or imported invalid values", () => {
  for (const size of [6, 14, 24, 48, 72]) expect(normalizeEditorFontSize(size)).toBe(size);
  for (const invalid of [NaN, Infinity, -Infinity, undefined, null, "24"]) {
    expect(normalizeEditorFontSize(invalid)).toBe(defaultSettings.fontSize);
  }
  expect(normalizeEditorFontSize(0)).toBe(6);
  expect(normalizeEditorFontSize(200)).toBe(72);
  expect(normalizeEditorFontSize(14.6)).toBe(15);
});

test("single updates and loaded settings normalize size and preserve font and ligature choices", () => {
  expect(normalizeSettingValue("fontSize", NaN)).toBe(defaultSettings.fontSize);
  expect(normalizeSettingValue("fontSize", 120)).toBe(72);
  for (const enabled of [true, false]) {
    const value = normalizeSettings({
      ...defaultSettings,
      fontSize: 24,
      fontFamily: "Microsoft YaHei",
      editorFontLigatures: enabled,
    });
    expect(value.fontSize).toBe(24);
    expect(value.fontFamily).toBe("Microsoft YaHei");
    expect(value.editorFontLigatures).toBe(enabled);
  }
});
