import { invoke } from "@/platform/tauri-core";

/**
 * Host API for contract v1 declarative plugin packages. The Rust
 * `plugin_host` module owns package storage and scanning; these wrappers are
 * the only frontend entry points. Decisions about the declarative host and
 * its coexistence with the Worker extension model are recorded in
 * .agents/notes/proposed/architecture/2026-10-22-windows-declarative-plugin-host.md
 */

export interface DeclarativePluginLanguage {
  id: string;
  displayName: string;
  fileExtensions: string[];
  fileNames: string[];
}

export interface DeclarativePluginRejection {
  code: string;
  message: string;
  path: string | null;
}

export interface DeclarativePluginSummary {
  pluginId: string;
  displayName: string;
  version: string;
  apiVersion: number;
  /** `bundled` packages ship with the app; `installed` live in the user store. */
  source: "bundled" | "installed";
  enabled: boolean;
  /** `rejected` packages are quarantined and never own a language. */
  status: "accepted" | "rejected";
  languages: DeclarativePluginLanguage[];
  rejection: DeclarativePluginRejection | null;
}

export interface DeclarativePluginLaunch {
  pluginId: string;
  languageId: string;
  serverPath: string;
  serverArgs: string[];
  initializationOptions: Record<string, unknown> | null;
  environment: Record<string, string>;
}

/** Rescans bundled and installed packages; call at startup and after installs. */
export function rescanDeclarativePlugins(): Promise<number> {
  return invoke<number>("declarative_plugins_rescan");
}

/** Returns the cached scan result; call `rescanDeclarativePlugins` first. */
export function listDeclarativePlugins(): Promise<DeclarativePluginSummary[]> {
  return invoke<DeclarativePluginSummary[]>("declarative_plugins_state");
}

/**
 * Resolves the launch of the enabled plugin that owns `filePath`, or `null`
 * when no accepted declarative plugin claims the file.
 */
export function resolveDeclarativePluginLaunch(
  filePath: string,
  workspacePath: string,
): Promise<DeclarativePluginLaunch | null> {
  return invoke<DeclarativePluginLaunch | null>("declarative_plugins_language_launch", {
    filePath,
    workspacePath,
  });
}
