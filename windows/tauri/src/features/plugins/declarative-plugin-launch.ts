import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { pluginPlanGuard } from "./declarative-plugin-lifecycle";
import { invoke } from "@/platform/tauri-core";
import { getPluginWebAppearance } from "./plugin-web-appearance";

/**
 * Host API for contract v1 declarative plugin packages. The Rust
 * `plugin_host` module owns package storage and scanning; these wrappers are
 * the only frontend entry points. Decisions about the declarative host and
 * its coexistence with the Worker extension model are recorded in
 * .agents/notes/implemented/architecture/2026-10-22-windows-declarative-plugin-host.md
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
  declaredSettings: DeclarativePluginSetting[];
  declaresTests: boolean;
  primaryLanguageId: string | null;
  rejection: DeclarativePluginRejection | null;
}

export interface DeclarativePluginSetting {
  id: string;
  type: "integer" | "enum" | "boolean" | "multiSelect" | "text" | "file" | "directory";
  title: string;
  description?: string | null;
  default: unknown;
  minimum?: number | null;
  maximum?: number | null;
  unit?: string | null;
  options?: Array<{ value: string; title: string }> | null;
  scope?: "global" | "project" | null;
  effect?: "restart" | "immediate" | "reload" | "nextRun" | null;
}

export interface DeclarativePluginLaunch {
  pluginId: string;
  languageId: string;
  serverPath: string;
  serverArgs: string[];
  initializationOptions: Record<string, unknown> | null;
  workspaceConfiguration: Record<string, unknown> | null;
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
export async function resolveDeclarativePluginLaunch(
  filePath: string,
  workspacePath: string,
): Promise<DeclarativePluginLaunch | null> {
  const guard = pluginPlanGuard();
  const launch = await invoke<DeclarativePluginLaunch | null>(
    "declarative_plugins_language_launch",
    {
      filePath,
      workspacePath,
    },
  );
  if (launch) guard(launch.pluginId);
  return launch;
}

/** Core's install review for one prepared package. */
export interface DeclarativePluginInstallReview {
  pluginId: string;
  version: string;
  permissions: string[];
  /** Full canonical program declarations, including arguments and templates. */
  programs: unknown[];
  newPrograms: unknown[];
}

/** A prepared disk import awaiting user confirmation. */
export interface PreparedDeclarativeInstall {
  sessionId: string;
  review: DeclarativePluginInstallReview;
  /** Digest the confirm call must present to prove the package is unchanged. */
  manifestDigest: string;
  displayName: string;
}

/** Prepares a disk import from a .zip archive or unpacked package directory. */
export function prepareDeclarativeDiskInstall(
  sourcePath: string,
): Promise<PreparedDeclarativeInstall> {
  return invoke<PreparedDeclarativeInstall>("declarative_plugins_prepare_disk_install", {
    sourcePath,
  });
}

/** Installs a confirmed snapshot; rejects when the package changed after review. */
export function confirmDeclarativeDiskInstall(
  sessionId: string,
  manifestDigest: string,
): Promise<DeclarativePluginSummary> {
  return invoke<DeclarativePluginSummary>("declarative_plugins_confirm_disk_install", {
    sessionId,
    manifestDigest,
  });
}

export function cancelDeclarativeDiskInstall(sessionId: string): Promise<void> {
  return invoke<void>("declarative_plugins_cancel_disk_install", { sessionId });
}

/** Removes an installed package and its state directory. */
export function uninstallDeclarativePlugin(pluginId: string): Promise<void> {
  return invoke<void>("declarative_plugins_uninstall", { pluginId });
}

/** Enables or disables an installed package; bundled packages reject this. */
export function setDeclarativePluginEnabled(pluginId: string, enabled: boolean): Promise<void> {
  return invoke<void>("declarative_plugins_set_enabled", { pluginId, enabled });
}

/** Restores the highest retained previous version of an installed package. */
export function rollbackDeclarativePlugin(pluginId: string): Promise<void> {
  return invoke<void>("declarative_plugins_rollback", { pluginId });
}

/** One declared setting, as Core normalizes it (settings capability v2). */
export interface DeclarativePluginSetting {
  id: string;
  type: "integer" | "enum" | "boolean" | "multiSelect" | "text" | "file" | "directory";
  title: string;
  description?: string | null;
  default: unknown;
  minimum?: number | null;
  maximum?: number | null;
  unit?: string | null;
  options?: Array<{ value: string; title: string }> | null;
  scope?: "global" | "project" | null;
  effect?: "restart" | "immediate" | "reload" | "nextRun" | null;
  page?: { languageID?: string; buildSystemID?: string } | null;
  section?: string | null;
  pattern?: string | null;
  maxLength?: number | null;
  placeholder?: string | null;
}

export interface DeclarativeSettingAction {
  id: string;
  title: string;
  description?: string;
  function: string;
  confirm?: boolean;
  page?: DeclarativePluginSetting["page"];
  section?: string;
}
export interface DeclarativeSettingSnapshot {
  manifest: Record<string, unknown>;
  settings: DeclarativePluginSetting[];
  settingActions: DeclarativeSettingAction[];
  globalValues: Record<string, unknown>;
  projectValues: Record<string, unknown>;
  resolvedGlobal: ResolvedDeclarativeSetting[];
  resolvedProject: ResolvedDeclarativeSetting[];
  globalPath: string;
  projectPath: string | null;
  identity: string;
  packageIdentity: string;
  reloadContext?: { workspaceId: string; registration: number; windowIncarnation: number };
}
export function loadDeclarativeSettingSnapshot(pluginId: string, workspacePath: string) {
  return invoke<DeclarativeSettingSnapshot>("declarative_plugins_setting_snapshot", {
    pluginId,
    workspacePath,
    workspaceId: workspaceRuntimeRegistry.getActiveWorkspaceId(),
  });
}

/** Effective value of one setting and the layer it came from. */
export interface ResolvedDeclarativeSetting {
  id: string;
  value: unknown;
  source: "default" | "global" | "project";
}

/** Effective values of one plugin's settings for one workspace. */
export function resolveDeclarativeSettings(
  manifest: Record<string, unknown>,
  workspacePath: string,
): Promise<{ status: string; settings?: ResolvedDeclarativeSetting[] }> {
  return invoke("declarative_plugins_resolve_settings", { manifest, workspacePath });
}

/** Stores a setting value in the requested layer; `null` erases it. */
export function storeDeclarativeSetting(
  pluginId: string,
  settingId: string,
  scope: "global" | "project",
  workspacePath: string,
  value: unknown,
  expectedIdentity: string,
): Promise<DeclarativeSettingSnapshot> {
  return invoke("declarative_plugins_store_setting", {
    pluginId,
    settingId,
    scope,
    workspacePath,
    value,
    expectedIdentity,
    workspaceId: workspaceRuntimeRegistry.getActiveWorkspaceId(),
  });
}

/** A running server's workspace configuration expanded with current values. */
export function declarativeWorkspaceConfiguration(
  manifest: Record<string, unknown>,
  languageId: string,
  workspacePath: string,
): Promise<{ status: string; configuration?: unknown }> {
  return invoke("declarative_plugins_workspace_configuration", {
    manifest,
    languageId,
    workspacePath,
  });
}

/** An expanded run or test plan ready for the shared run pipeline. */
export interface DeclarativeRunPlan {
  pluginId: string;
  languageId: string;
  executable: { command?: string | null; toolchain?: string | null; tool?: string | null };
  arguments: string[];
  workingDirectory: string;
  label?: string | null;
  frameworkId?: string | null;
  identity?: string;
}

export interface DeclarativeExecutionContext {
  clientId: string;
  workspaceId: string;
  workspacePath: string;
  generation: string;
}
export function setDeclarativeExecutionContext(
  clientId: string,
  revision: number,
  context: DeclarativeExecutionContext | null,
) {
  return invoke<void>("declarative_plugins_execution_context", { clientId, revision, context });
}
export type DeclarativeTestScope =
  | { kind: "workspace" }
  | { kind: "file"; relativeFilePath: string }
  | { kind: "testCase"; identifier: string; relativeFilePath?: string }
  | { kind: "suite"; identifier: string };
export type DeclarativeExecutionSelection =
  | { kind: "run"; relativeFilePath: string; userArguments: string[] }
  | { kind: "test"; scope: DeclarativeTestScope };
export interface DeclarativeTestItem {
  id: string;
  label: string;
  kind: "workspace" | "file";
  relativeFilePath?: string;
}

export function discoverDeclarativeTests(
  pluginId: string,
  languageId: string,
  context: DeclarativeExecutionContext,
) {
  return invoke<{ items: DeclarativeTestItem[]; identity: string }>(
    "declarative_plugins_discover_tests",
    {
      pluginId,
      languageId,
      context,
    },
  );
}

/** Native rechecks the receipt and owns executable resolution/process start. */
export function startDeclarativeExecution(args: {
  pluginId: string;
  languageId: string;
  context: DeclarativeExecutionContext;
  selection: DeclarativeExecutionSelection;
  expectedIdentity: string;
  sessionId: string;
  executionId: string;
}) {
  return invoke<void>("declarative_plugins_start_execution", { ...args });
}

/** Expands the run template for one file of a plugin-owned language. */
export function resolveDeclarativeRunPlan(
  pluginId: string,
  languageId: string,
  relativeFilePath: string,
  userArguments: string[] = [],
  context?: DeclarativeExecutionContext,
): Promise<DeclarativeRunPlan> {
  return invoke<DeclarativeRunPlan>("declarative_plugins_run_plan", {
    pluginId,
    languageId,
    relativeFilePath,
    userArguments,
    ...(context ? { context } : {}),
  });
}

/** Expands the workspace test template for a plugin-owned language. */
export function resolveDeclarativeTestPlan(
  pluginId: string,
  languageId: string,
  workspacePath: string,
  scope?: DeclarativeTestScope,
  context?: DeclarativeExecutionContext,
): Promise<DeclarativeRunPlan> {
  return invoke<DeclarativeRunPlan>("declarative_plugins_test_plan", {
    pluginId,
    languageId,
    workspacePath,
    ...(scope ? { scope } : {}),
    ...(context ? { context } : {}),
  });
}

/** One host-rendered text or web tool window (ui capabilities 1 and 2). */
export interface DeclarativeWebToolWindow {
  windowId: string;
  pluginId: string;
  title: string;
  placement: string;
  order: number | null;
  entry: string;
}

/** Declared web tool windows of all accepted, enabled packages. */
export function listDeclarativeWebWindows(): Promise<DeclarativeWebToolWindow[]> {
  return invoke<DeclarativeWebToolWindow[]>("declarative_plugins_web_windows");
}

/** Opens (or focuses) the web view of one tool window. */
export function openDeclarativeWebWindow(pluginId: string, windowId: string): Promise<void> {
  return invoke<void>("declarative_plugins_open_web_window", {
    pluginId,
    windowId,
    workspaceId: workspaceRuntimeRegistry.getActiveWorkspaceId(),
    workspacePath: useFileSystemStore.getState().rootFolderPath,
    appearance: getPluginWebAppearance(),
  });
}

/** Destroys the web view of one tool window. */
export function closeDeclarativeWebWindow(pluginId: string, windowId: string): Promise<void> {
  return invoke<void>("declarative_plugins_close_web_window", {
    pluginId,
    windowId,
    workspaceId: workspaceRuntimeRegistry.getActiveWorkspaceId(),
  });
}

/** Returns the raw manifest of one accepted declarative plugin. */
export function getDeclarativePluginManifest(
  pluginId: string,
): Promise<Record<string, unknown> | null> {
  return invoke<Record<string, unknown> | null>("declarative_plugins_manifest", { pluginId });
}

/** The enabled declarative plugin that owns a file, or null. */
export function invokeDeclarativePluginOwner(filePath: string): Promise<{
  pluginId: string;
  displayName: string;
  languageId: string;
} | null> {
  return invoke("declarative_plugins_language_owner", { filePath });
}
