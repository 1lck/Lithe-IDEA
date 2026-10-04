import { describe, expect, test } from "bun:test";
import {
  DEFAULT_HIDDEN_DIRECTORY_PATTERNS,
  DEFAULT_HIDDEN_FILE_PATTERNS,
} from "@/features/settings/config/default-settings";
import {
  findRetiredSettingsKeys,
  HIDDEN_PATTERN_DEFAULTS_VERSION_KEY,
  migrateHiddenPatternDefaults,
  migrateProjectOpenDestination,
  PROJECT_OPEN_DESTINATION_KEY,
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

describe("project open destination migration", () => {
  // The legacy boolean's false branch was the old same-window behavior, which attached the
  // project as a tab; it must not become the new replace semantics after the upgrade.
  test.each([
    [true, "new-window"],
    [false, "attach"],
  ] as const)("maps openFoldersInNewWindow %s to %s", (legacyValue, expected) => {
    const result = migrateProjectOpenDestination(
      new Map<string, unknown>([["openFoldersInNewWindow", legacyValue]]),
    );

    expect(result.entries.get(PROJECT_OPEN_DESTINATION_KEY)).toBe(expected);
    expect(result.changes).toEqual([[PROJECT_OPEN_DESTINATION_KEY, expected]]);
    expect(result.entries.has("openFoldersInNewWindow")).toBe(true);
  });

  test("does not overwrite an existing destination", () => {
    const result = migrateProjectOpenDestination(
      new Map<string, unknown>([
        ["openFoldersInNewWindow", true],
        [PROJECT_OPEN_DESTINATION_KEY, "attach"],
      ]),
    );

    expect(result.changes).toEqual([]);
    expect(result.entries.get(PROJECT_OPEN_DESTINATION_KEY)).toBe("attach");
  });

  test("leaves stores without the legacy key untouched", () => {
    const result = migrateProjectOpenDestination(new Map<string, unknown>([["wordWrap", false]]));

    expect(result.changes).toEqual([]);
    expect(result.entries.has(PROJECT_OPEN_DESTINATION_KEY)).toBe(false);
  });
});
