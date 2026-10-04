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

// Keys of settings that no longer exist. They are deleted from the persisted store so an
// upgraded settings.json does not keep carrying values that nothing reads.
export const RETIRED_SETTINGS_KEYS: readonly string[] = [
  "horizontalTabScroll",
  "rememberLastGitPanelMode",
  "gitLastPanelMode",
  "gitSidebarTabOrder",
  "openFoldersInNewWindow",
];

export const PROJECT_OPEN_DESTINATION_KEY = "projectOpenDefaultDestination";
const LEGACY_OPEN_FOLDERS_IN_NEW_WINDOW_KEY = "openFoldersInNewWindow";

interface ProjectOpenDestinationMigration {
  entries: Map<string, unknown>;
  changes: Array<[string, unknown]>;
}

// Maps the retired openFoldersInNewWindow boolean onto the destination tri-state. The
// boolean's false branch named the old same-window behavior, which attached the new project
// as a tab, so it maps to "attach" (not "this-window") to keep upgraded installs behaving
// the same.
export function deriveProjectOpenDestinationFromLegacy(legacyValue: unknown) {
  return legacyValue === true ? "new-window" : "attach";
}

// Fills projectOpenDefaultDestination from the retired boolean when no explicit destination
// was persisted. Must run before RETIRED_SETTINGS_KEYS deletion drops the legacy key.
export function migrateProjectOpenDestination(
  sourceEntries: Map<string, unknown>,
): ProjectOpenDestinationMigration {
  const entries = new Map(sourceEntries);
  const changes: Array<[string, unknown]> = [];

  if (entries.has(PROJECT_OPEN_DESTINATION_KEY)) {
    return { entries, changes };
  }

  const legacyValue = entries.get(LEGACY_OPEN_FOLDERS_IN_NEW_WINDOW_KEY);
  if (legacyValue === undefined || legacyValue === null) {
    return { entries, changes };
  }

  const destination = deriveProjectOpenDestinationFromLegacy(legacyValue);
  entries.set(PROJECT_OPEN_DESTINATION_KEY, destination);
  changes.push([PROJECT_OPEN_DESTINATION_KEY, destination]);

  return { entries, changes };
}

export function findRetiredSettingsKeys(entries: ReadonlyMap<string, unknown>): string[] {
  return RETIRED_SETTINGS_KEYS.filter((key) => entries.has(key));
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
