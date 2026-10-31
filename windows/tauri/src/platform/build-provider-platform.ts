import { pluginPlanGuard } from "@/features/plugins/declarative-plugin-lifecycle";
import { invoke } from "@/platform/tauri-core";
import { buildCore } from "./build-core-api";
import { windowsBuildProviders } from "./build-provider-sessions";
import { WindowsBuildProviderWorkspace, type BuildInstance, type BuildModel } from "@/features/build/services/build-provider-workspace";
import { createTranslator } from "@/i18n/locale";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { watchBuildConfiguration, type BuildConfigurationSourceVersion, type BuildConfigurationCheck } from "@/features/build/services/build-configuration-watch";
import { documentWatchInputs } from "./document-watch-inputs";
import type { CoreBuildProviderTarget } from "./lsp-core-adapter";

export interface WindowsBuildCatalog {
  detection: {
    instances: Array<BuildInstance & { id: string; displayName: string; modelSource: string | null;
      optionFingerprint: string; droppedOptions: string[]; model?: BuildModel }>;
    rejected: Array<{ index: number; error: { code: string; message: string } }>;
    shadowed: Array<{ pluginID: string; buildSystemID: string; by: string }>;
  };
  plugins: Array<{ manifest: Record<string, unknown> }>;
  document: { version: 1; systems: Record<string, unknown> };
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
    tools: (target, root, checkVersions) => invoke("declarative_plugins_build_tool", { ...target, root, checkVersions }),
    configurationCheck: check,
    configurationFiles: {
      prepare: (target, root, operationId, snapshot, edits) => invoke("declarative_plugins_build_prepare_configuration", { ...target, root, operationId, snapshot, edits }),
      commit: operationId => invoke("declarative_plugins_build_commit_configuration", { operationId }),
      cancel: operationId => invoke("declarative_plugins_build_cancel_configuration", { operationId }),
    },
    watchConfiguration: (target, sources, changed) => watchBuildConfiguration(() => check(target, sources), changed, documentWatchInputs),
  });
}
