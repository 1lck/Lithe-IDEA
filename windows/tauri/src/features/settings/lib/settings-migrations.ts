import {
  DEFAULT_HIDDEN_DIRECTORY_PATTERNS,
  DEFAULT_HIDDEN_FILE_PATTERNS,
} from "@/features/settings/config/default-settings";

export const HIDDEN_PATTERN_DEFAULTS_VERSION_KEY = "hiddenPatternDefaultsVersion";
const CURRENT_HIDDEN_PATTERN_DEFAULTS_VERSION = 1;

interface HiddenPatternDefaultsMigration {
  entries: Map<string, unknown>;
  changes: Array<[string, unknown]>;
}

const isEmptyArray = (value: unknown): value is [] => Array.isArray(value) && value.length === 0;

export function migrateHiddenPatternDefaults(
  sourceEntries: Map<string, unknown>,
): HiddenPatternDefaultsMigration {
  const entries = new Map(sourceEntries);
  const version = entries.get(HIDDEN_PATTERN_DEFAULTS_VERSION_KEY);
  const changes: Array<[string, unknown]> = [];

  if (typeof version === "number" && version >= CURRENT_HIDDEN_PATTERN_DEFAULTS_VERSION) {
    return { entries, changes };
  }

  const hasLegacyEmptyDefaults =
    entries.has("hiddenFilePatterns") &&
    entries.has("hiddenDirectoryPatterns") &&
    isEmptyArray(entries.get("hiddenFilePatterns")) &&
    isEmptyArray(entries.get("hiddenDirectoryPatterns"));

  if (hasLegacyEmptyDefaults) {
    const hiddenFilePatterns = [...DEFAULT_HIDDEN_FILE_PATTERNS];
    const hiddenDirectoryPatterns = [...DEFAULT_HIDDEN_DIRECTORY_PATTERNS];
    entries.set("hiddenFilePatterns", hiddenFilePatterns);
    entries.set("hiddenDirectoryPatterns", hiddenDirectoryPatterns);
    changes.push(
      ["hiddenFilePatterns", hiddenFilePatterns],
      ["hiddenDirectoryPatterns", hiddenDirectoryPatterns],
    );
  }

  entries.set(HIDDEN_PATTERN_DEFAULTS_VERSION_KEY, CURRENT_HIDDEN_PATTERN_DEFAULTS_VERSION);
  changes.push([HIDDEN_PATTERN_DEFAULTS_VERSION_KEY, CURRENT_HIDDEN_PATTERN_DEFAULTS_VERSION]);

  return { entries, changes };
}
