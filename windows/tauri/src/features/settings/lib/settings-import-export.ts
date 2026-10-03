import {
  defaultSettings,
  getDefaultSettingsSnapshot,
} from "@/features/settings/config/default-settings";
import { deriveProjectOpenDestinationFromLegacy } from "./settings-migrations";
import { normalizeSettings } from "@/features/settings/lib/settings-normalization";
import type { Settings } from "@/features/settings/types/settings.types";

const SETTINGS_EXPORT_FORMAT = "lithe.settings";
const SETTINGS_EXPORT_VERSION = 1;

export interface SettingsExportPayload {
  format: typeof SETTINGS_EXPORT_FORMAT;
  version: typeof SETTINGS_EXPORT_VERSION;
  exportedAt: string;
  settings: Settings;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function cloneSettings(settings: Settings): Settings {
  return JSON.parse(JSON.stringify(settings)) as Settings;
}

function pickSettings(value: unknown): Partial<Settings> | null {
  if (!isRecord(value)) {
    return null;
  }

  const settings: Partial<Settings> = {};

  for (const key of Object.keys(defaultSettings) as Array<keyof Settings>) {
    if (key in value) {
      (settings as Record<string, unknown>)[key] = value[key];
    }
  }

  // Legacy exports carry openFoldersInNewWindow instead of the destination tri-state.
  // Keep the retired key so normalizeSettings can derive the destination from it —
  // including when the export's destination value is invalid.
  if ("openFoldersInNewWindow" in value) {
    (settings as Record<string, unknown>).openFoldersInNewWindow = value.openFoldersInNewWindow;
  }

  return settings;
}

function getSettingsCandidate(value: unknown): unknown {
  if (
    isRecord(value) &&
    value.format === SETTINGS_EXPORT_FORMAT &&
    value.version === SETTINGS_EXPORT_VERSION
  ) {
    return value.settings;
  }

  return value;
}

export function createSettingsExportPayload(settings: Settings): SettingsExportPayload {
  return {
    format: SETTINGS_EXPORT_FORMAT,
    version: SETTINGS_EXPORT_VERSION,
    exportedAt: new Date().toISOString(),
    settings: cloneSettings(settings),
  };
}

export function parseSettingsImportJson(jsonString: string): Settings | null {
  const parsed = JSON.parse(jsonString);
  const candidate = getSettingsCandidate(parsed);
  const importedSettings = pickSettings(candidate);

  if (!importedSettings || Object.keys(importedSettings).length === 0) {
    return null;
  }

  const merged = {
    ...getDefaultSettingsSnapshot(),
    ...importedSettings,
  } as Settings & { openFoldersInNewWindow?: unknown };

  // Legacy exports carry openFoldersInNewWindow instead of the destination tri-state.
  // Derive the destination only when the import did not also carry an explicit one,
  // because the defaults merge above would otherwise mask the legacy value.
  if (merged.openFoldersInNewWindow !== undefined) {
    if (importedSettings.projectOpenDefaultDestination === undefined) {
      merged.projectOpenDefaultDestination = deriveProjectOpenDestinationFromLegacy(
        merged.openFoldersInNewWindow,
      );
    }
    delete merged.openFoldersInNewWindow;
  }

  return normalizeSettings(merged);
}
