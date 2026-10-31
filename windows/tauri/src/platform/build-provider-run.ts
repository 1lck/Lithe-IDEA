import { declarativePluginProcessOwner } from "@/features/plugins/declarative-plugin-process-owner";
import { startBuildProviderRun, type BuildProviderRunRequest } from "@/features/run/services/build-provider-run-launch";
import { buildProviderLaunchInputs } from "@/features/run/api/run-core-api";
import { resolveRunLaunch, startRunProcess, stopRunProcess } from "@/features/run/api/run-host-api";
import { createTranslator } from "@/i18n/locale";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { windowsBuildWorkspaces } from "./build-workspaces";
import { invoke } from "./tauri-core";

/** Admission comes from the compiled native host. Until the migration is
 * admitted, existing framework/module configurations retain their old route. */
export async function isWindowsBuildProviderRunAdmitted(jvmDebug: boolean): Promise<boolean> {
  const capabilities = await invoke<Record<string, unknown>>("declarative_plugins_host_capabilities");
  if (!capabilities || typeof capabilities !== "object" || Array.isArray(capabilities)) {
    throw Object.assign(new Error(createTranslator(useSettingsStore.getState().settings.displayLanguage)("build.errors.unsupportedSource")), { code: "invalid_response" });
  }
  return Array.isArray(capabilities.buildSystems) && capabilities.buildSystems.includes(3)
    && Array.isArray(capabilities.buildProviders) && capabilities.buildProviders.includes(jvmDebug ? 11 : 10);
}

export function startWindowsBuildProviderRun(request: BuildProviderRunRequest) {
  return startBuildProviderRun(request, {
    workspace: (id, root) => windowsBuildWorkspaces.get(id, root), inputs: buildProviderLaunchInputs,
    processes: declarativePluginProcessOwner, resolve: resolveRunLaunch, start: startRunProcess, stop: stopRunProcess,
    unavailable: () => new Error(createTranslator(useSettingsStore.getState().settings.displayLanguage)("build.errors.inputsChanged")),
  });
}
