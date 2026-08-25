import { describe, expect, test } from "bun:test";
import {
  DEFAULT_HIDDEN_DIRECTORY_PATTERNS,
  DEFAULT_HIDDEN_FILE_PATTERNS,
} from "@/features/settings/config/default-settings";
import {
  HIDDEN_PATTERN_DEFAULTS_VERSION_KEY,
  migrateHiddenPatternDefaults,
} from "./settings-migrations";

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
