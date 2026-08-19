import { invoke } from "@/platform/tauri-core";

export type LogFallbackReason = "unavailable" | "not_writable" | "logging_unavailable";

export interface LogSettingsSnapshot {
  default_path: string;
  configured_path: string | null;
  effective_path: string;
  fallback_reason: LogFallbackReason | null;
  diagnostic_enabled: boolean;
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

export function getLogSettings() {
  return invoke<LogSettingsSnapshot>("get_log_settings");
}

export function setLogDirectory(parentPath: string | null) {
  return invoke<LogDirectoryChangeResult>("set_log_directory", {
    parentPath,
  });
}

export function setDiagnosticLogging(enabled: boolean) {
  return invoke<LogSettingsSnapshot>("set_diagnostic_logging", { enabled });
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
