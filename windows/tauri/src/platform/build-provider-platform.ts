import { pluginPlanGuard } from "@/features/plugins/declarative-plugin-lifecycle";
import { invoke } from "@/platform/tauri-core";
import { buildCore } from "./build-core-api";
import { windowsBuildProviders } from "./build-provider-sessions";
import { WindowsBuildProviderWorkspace } from "@/features/build/services/build-provider-workspace";
import { createTranslator } from "@/i18n/locale";
import { useSettingsStore } from "@/features/settings/stores/settings.store";

export function createWindowsBuildProviderWorkspace(workspacePath: string): WindowsBuildProviderWorkspace {
  return new WindowsBuildProviderWorkspace(workspacePath, {
    core: buildCore, providers: windowsBuildProviders, guard: pluginPlanGuard,
    translate: key => createTranslator(useSettingsStore.getState().settings.displayLanguage)(key),
    tools: (target, root, checkVersions) => invoke("declarative_plugins_build_tool", { ...target, root, checkVersions }),
  });
}
