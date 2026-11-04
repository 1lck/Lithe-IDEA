import { declarativePluginProcessOwner } from "@/features/plugins/declarative-plugin-process-owner";
import { startBuildProviderRun, type BuildProviderRunRequest } from "@/features/run/services/build-provider-run-launch";
import { buildProviderLaunchInputs } from "@/features/run/api/run-core-api";
import { resolveRunLaunch, startRunProcess, stopRunProcess } from "@/features/run/api/run-host-api";
import { createTranslator } from "@/i18n/locale";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { windowsBuildWorkspaces } from "./build-workspaces";

export function startWindowsBuildProviderRun(request: BuildProviderRunRequest) {
  return startBuildProviderRun(request, {
    workspace: (id, root) => windowsBuildWorkspaces.get(id, root), inputs: buildProviderLaunchInputs,
    processes: declarativePluginProcessOwner, resolve: resolveRunLaunch, start: startRunProcess, stop: stopRunProcess,
    unavailable: () => new Error(createTranslator(useSettingsStore.getState().settings.displayLanguage)("build.errors.inputsChanged")),
  });
}
