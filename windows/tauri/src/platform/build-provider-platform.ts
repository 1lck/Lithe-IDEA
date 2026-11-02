import { pluginPlanGuard } from "@/features/plugins/declarative-plugin-lifecycle";
import { invoke } from "@/platform/tauri-core";
import { buildCore } from "./build-core-api";
import { windowsBuildProviders } from "./build-provider-sessions";
import { WindowsBuildProviderWorkspace, type BuildInstance, type BuildModel } from "@/features/build/services/build-provider-workspace";
import { createTranslator } from "@/i18n/locale";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { translatePluginHostFailure } from "@/features/plugins/plugin-native-errors";
import { watchBuildConfiguration, type BuildConfigurationSourceVersion, type BuildConfigurationCheck } from "@/features/build/services/build-configuration-watch";
import { documentWatchInputs } from "./document-watch-inputs";
import type { CoreBuildProviderTarget } from "./lsp-core-adapter";
import { prepareNativeBuildTool } from "./build-tool-preparation";

export interface WindowsBuildCatalog {
  detection: {
    instances: Array<BuildInstance & { id: string; displayName: string; modelSource: string | null;
      optionFingerprint: string; droppedOptions: string[]; model?: BuildModel }>;
    rejected: Array<{ index: number; error: { code: string; message: string } }>;
    shadowed: Array<{ pluginID: string; buildSystemID: string; by: string }>;
  };
  plugins: Array<{ manifest: Record<string, unknown> }>;
  document: { version: 1; systems: Record<string, unknown> };
  optionsRevision?: string;
}

export async function saveWindowsBuildOption(workspacePath: string, entry: BuildInstance, optionID: string, value: unknown,
  expectedRevision: string, modelValues: BuildModel["optionValues"] | undefined, signal: AbortSignal): Promise<BuildOptionsResolution> {
  try {
    return await prepareNativeBuildTool({
      begin: () => invoke<string>("declarative_plugins_begin_tool_preparation"),
      resolve: operationId => invoke("declarative_plugins_build_save_option", { workspacePath, pluginId: entry.pluginID,
        buildSystemId: entry.buildSystemID, root: entry.root, optionId: optionID, value, modelValues, expectedRevision, operationId }),
      cancel: operationId => invoke("declarative_plugins_cancel_tool_preparation", { operationId }),
    },signal);
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : String(cause);
    const key = message.includes("build.options.conflict") ? "build.options.conflict" : "build.options.invalid";
    throw Object.assign(new Error(createTranslator(useSettingsStore.getState().settings.displayLanguage)(key)),{cause});
  }
}

export interface BuildResolvedOption {
  id: string; displayName: string; kind: "boolean" | "singleSelect" | "multiSelect" | "text" | "file" | "directory";
  scope?: "workspace" | "instance"; value: unknown; source: "user" | "default" | "none";
  choices: Array<{value: string; title: string | null}>; allowCustom: boolean;
}
export interface BuildOptionsResolution { options: BuildResolvedOption[]; dropped: string[]; fingerprint: string }

export async function resolveWindowsBuildOptions(path: string, manifest: Record<string,unknown>, entry: BuildInstance, modelValues?: BuildModel["optionValues"]) {
  return (await buildCore<{options: BuildOptionsResolution}>("build.resolveOptions",manifest,entry.buildSystemID,
    {options:entry.options,modelValues},path)).options;
}

export async function detectWindowsBuildProjects(workspacePath: string): Promise<WindowsBuildCatalog> {
  try { return await invoke("declarative_plugins_build_detect", { workspacePath }); }
  catch (cause) {
    throw Object.assign(new Error(createTranslator(useSettingsStore.getState().settings.displayLanguage)("build.errors.detectionFailed")), { cause });
  }
}

export function createWindowsBuildProviderWorkspace(workspacePath: string): WindowsBuildProviderWorkspace {
  const check = (target: CoreBuildProviderTarget, sources: BuildConfigurationSourceVersion[]): Promise<BuildConfigurationCheck> =>
    invoke("declarative_plugins_build_check_configuration", { pluginId: target.pluginId, buildSystemId: target.buildSystemId, sources });
  return new WindowsBuildProviderWorkspace(workspacePath, {
    core: buildCore, providers: windowsBuildProviders, guard: pluginPlanGuard,
    translate: key => createTranslator(useSettingsStore.getState().settings.displayLanguage)(key),
    tools: async (target, root, checkVersions, configurationID, signal) => {
      try { return await prepareNativeBuildTool({
        begin: () => invoke<string>("declarative_plugins_begin_tool_preparation"),
        resolve: operationId => invoke("declarative_plugins_build_tool", { ...target, root, checkVersions, configurationId: configurationID, operationId }),
        cancel: operationId => invoke<void>("declarative_plugins_cancel_tool_preparation", { operationId }),
      }, signal); }
      catch (cause) {
        throw translatePluginHostFailure(cause, createTranslator(useSettingsStore.getState().settings.displayLanguage));
      }
    },
    configurationCheck: check,
    configurationFiles: {
      prepare: (target, root, operationId, snapshot, edits) => invoke("declarative_plugins_build_prepare_configuration", { ...target, root, operationId, snapshot, edits }),
      commit: (operationId, receipt) => invoke("declarative_plugins_build_commit_configuration", { operationId, receipt }),
      cancel: operationId => invoke("declarative_plugins_build_cancel_configuration", { operationId }),
    },
    watchConfiguration: (target, sources, changed) => watchBuildConfiguration(() => check(target, sources), changed, documentWatchInputs),
  });
}
