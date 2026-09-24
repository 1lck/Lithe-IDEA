import { describe, expect, test } from "bun:test";
import {
  DEFAULT_HIDDEN_DIRECTORY_PATTERNS,
  DEFAULT_HIDDEN_FILE_PATTERNS,
} from "@/features/settings/config/default-settings";
import {
  findRetiredSettingsKeys,
  HIDDEN_PATTERN_DEFAULTS_VERSION_KEY,
  migrateHiddenPatternDefaults,
} from "./settings-migrations";
import { defaultSettings } from "@/features/settings/config/default-settings";

describe("hidden pattern default migration", () => {
  test("replaces the former pair of empty defaults", () => {
    const result = migrateHiddenPatternDefaults(
      new Map<string, unknown>([
        ["hiddenFilePatterns", []],
        ["hiddenDirectoryPatterns", []],
      ]),
    );

    expect(result.entries.get("hiddenFilePatterns")).toEqual([...DEFAULT_HIDDEN_FILE_PATTERNS]);
    expect(result.entries.get("hiddenDirectoryPatterns")).toEqual([
      ...DEFAULT_HIDDEN_DIRECTORY_PATTERNS,
    ]);
    expect(result.entries.get(HIDDEN_PATTERN_DEFAULTS_VERSION_KEY)).toBe(1);
  });

  test("preserves user-customized pattern lists", () => {
    const result = migrateHiddenPatternDefaults(
      new Map([
        ["hiddenFilePatterns", ["*.generated"]],
        ["hiddenDirectoryPatterns", []],
      ]),
    );

    expect(result.entries.get("hiddenFilePatterns")).toEqual(["*.generated"]);
    expect(result.entries.get("hiddenDirectoryPatterns")).toEqual([]);
  });

  test("does not rewrite a completed migration", () => {
    const result = migrateHiddenPatternDefaults(
      new Map<string, unknown>([
        [HIDDEN_PATTERN_DEFAULTS_VERSION_KEY, 1],
        ["hiddenFilePatterns", []],
        ["hiddenDirectoryPatterns", []],
      ]),
    );

    expect(result.changes).toEqual([]);
  });
});

describe("retired settings cleanup", () => {
  test("finds the removed buffer carousel key in a persisted store", () => {
    const entries = new Map<string, unknown>([
      ["horizontalTabScroll", true],
      ["wordWrap", false],
    ]);

    expect(findRetiredSettingsKeys(entries)).toEqual(["horizontalTabScroll"]);
  });

  test("ignores stores without retired keys", () => {
    expect(findRetiredSettingsKeys(new Map([["wordWrap", false]]))).toEqual([]);
  });

  test("never retires a key that is still a live setting", () => {
    const retired = findRetiredSettingsKeys(new Map(Object.entries(defaultSettings)));

    expect(retired).toEqual([]);
  });
});
