import { invoke } from "@/platform/tauri-core";

export type LogFallbackReason = "unavailable" | "not_writable" | "logging_unavailable";

export interface LogSettingsSnapshot {
  default_path: string;
  configured_path: string | null;
  effective_path: string;
  fallback_reason: LogFallbackReason | null;
  diagnostic_enabled: boolean;
  diagnostic_category?: string | null;
  dropped_events?: number;
  write_failures?: number;
}

export interface LogDirectoryChangeResult {
  settings: LogSettingsSnapshot;
  previous_custom_path: string | null;
  previous_log_bytes: number;
}

export interface ClearLogResult {
  deleted_files: number;
  freed_bytes: number;
}

export interface LogSelection {
  category?: string | null;
  minimumLevel?: string | null;
  session?: "current" | "previous" | "all";
  search?: string | null;
  since?: string | null;
  until?: string | null;
}

export interface LogTimeline {
  content: string;
  truncated: boolean;
  matchedLines: number;
}

export function queryLitheLogs(selection: LogSelection) {
  return invoke<LogTimeline>("query_lithe_logs", { selection });
}

export interface DiagnosticBundlePreview {
  snapshotId: string;
  manifest: {
    schemaVersion: number;
    generatedAtEpochMilliseconds: number;
    environment: {
      appVersion: string;
      osName: string;
      osVersion: string;
      cpuCoreCount: number;
      memoryRssBytes: number;
      diskFreeBytes: number;
    };
    files: Array<{
      relativePath: string;
      sizeBytes: number;
      description: string;
    }>;
  };
}

export interface DiagnosticBundleResult {
  destinationPath: string;
  includedRelativePaths: string[];
  totalSizeBytes: number;
}

export function getLogSettings() {
  return invoke<LogSettingsSnapshot>("get_log_settings");
}

export function setLogDirectory(parentPath: string | null) {
  return invoke<LogDirectoryChangeResult>("set_log_directory", {
    parentPath,
  });
}

export function setDiagnosticLogging(enabled: boolean, category: string | null = null) {
  return invoke<LogSettingsSnapshot>("set_diagnostic_logging", { enabled, category });
}

export function clearLitheLogs() {
  return invoke<ClearLogResult>("clear_lithe_logs");
}

export function resolvePreviousLogCleanup(deleteLogs: boolean) {
  return invoke<ClearLogResult>("resolve_previous_log_cleanup", {
    delete: deleteLogs,
  });
}

export function openLogDirectory() {
  return invoke<void>("open_log_directory");
}

export function previewDiagnosticBundle(selection?: LogSelection) {
  return invoke<DiagnosticBundlePreview>("preview_diagnostic_bundle", {
    selection: selection ?? null,
  });
}

export function exportDiagnosticBundle(destinationPath: string, snapshotId: string) {
  return invoke<DiagnosticBundleResult>("export_diagnostic_bundle", {
    destinationPath,
    snapshotId,
  });
}

export function discardDiagnosticBundle(snapshotId: string) {
  return invoke<void>("discard_diagnostic_bundle", { snapshotId });
}
