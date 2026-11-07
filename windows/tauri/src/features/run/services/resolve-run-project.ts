import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { createTranslator } from "@/i18n/locale";
import { mavenLaunchContextForWorkspace } from "@/features/maven/stores/maven.store";
import { formatArgumentTexts, resolveRunConfiguration } from "../api/run-core-api";
import { discoverRunToolchains } from "../api/run-host-api";
import { workspaceToolchainSelection } from "../utils/workspace-toolchain-paths";
import {
  EMPTY_GLOBAL_TOOLCHAIN,
  type GenericRuntime,
  type GlobalToolchain,
  type JavaRuntime,
  type MavenRuntime,
  type RunConfiguration,
  type RunDiagnostic,
} from "../types/run.types";
import {
  configurationUsesMaven,
  effectiveRuntimeExecutablePaths,
  mapCoreConfiguration,
  mapCoreToolchain,
  mapDiagnostics,
  selectedToolchainCandidates,
} from "../utils/run-configuration";

const defaultDependencies = {
  discoverRunToolchains,
  resolveRunConfiguration,
  formatArgumentTexts,
  mavenLaunchContextForWorkspace,
};

export interface ResolvedRunProject {
  configurations: RunConfiguration[];
  diagnostics: RunDiagnostic[];
  defaultConfigurationId: string | null;
  discoveredJava: JavaRuntime[];
  discoveredMaven: MavenRuntime[];
  discoveredRuntimes: GenericRuntime[];
  globalToolchain: GlobalToolchain;
  effectiveRuntimeExecutablePaths: Record<string, string>;
}

export async function resolveConfigurations(
  root: string,
  workspaceId: string,
  dependencies = defaultDependencies,
): Promise<ResolvedRunProject> {
  const automatic = await dependencies.discoverRunToolchains(root);
  const automaticRuntimePaths = effectiveRuntimeExecutablePaths(automatic.runtimes, {});
  const preliminary = await dependencies.resolveRunConfiguration(
    root,
    selectedToolchainCandidates(automatic, {
      ...EMPTY_GLOBAL_TOOLCHAIN,
      runtimeExecutablePaths: automaticRuntimePaths,
    }),
  );
  const globalToolchain = mapCoreToolchain(preliminary.toolchain, preliminary.localToolchains);
  const usesMaven = (preliminary.configurations ?? []).some((configuration) =>
    configurationUsesMaven(configuration),
  );
  const mavenContext = usesMaven
    ? await dependencies.mavenLaunchContextForWorkspace(root, [], workspaceId)
    : null;
  // Keep persisted Run selections separate from the Maven panel fallback.
  // Displaying a diagnostic must not copy that fallback into Run configuration.
  const effectiveToolchain = workspaceToolchainSelection(root, {
    ...globalToolchain,
    mavenExecutablePath:
      globalToolchain.mavenExecutablePath || mavenContext?.mavenExecutablePath || "",
  });
  const hasSelectedToolchain = Boolean(
    globalToolchain.javaHomePath ||
    effectiveToolchain.mavenExecutablePath ||
    Object.values(globalToolchain.runtimeExecutablePaths).some(Boolean),
  );
  const discovered = hasSelectedToolchain
    ? await dependencies.discoverRunToolchains(root, effectiveToolchain)
    : automatic;
  const effectiveRuntimePaths = effectiveRuntimeExecutablePaths(
    discovered.runtimes,
    effectiveToolchain.runtimeExecutablePaths,
  );
  const candidates = selectedToolchainCandidates(discovered, {
    ...effectiveToolchain,
    runtimeExecutablePaths: effectiveRuntimePaths,
  });
  const resolved = hasSelectedToolchain
    ? await dependencies.resolveRunConfiguration(root, candidates)
    : preliminary;
  const configurations = (resolved.configurations ?? []).map(mapCoreConfiguration);
  const argumentLists = configurations.flatMap((configuration) => [
    configuration.jvmArguments, configuration.programArguments,
  ]);
  const argumentTexts = argumentLists.length === 0
    ? []
    : await dependencies.formatArgumentTexts(argumentLists);
  if (argumentTexts.length !== argumentLists.length) {
    throw new Error(createTranslator(useSettingsStore.getState().settings.displayLanguage)("run.invalidTitle"));
  }
  configurations.forEach((configuration, index) => {
    configuration.editorArgumentText = { vm: argumentTexts[index * 2], program: argumentTexts[index * 2 + 1] };
  });
  return {
    configurations,
    diagnostics: mapDiagnostics(resolved.diagnostics),
    defaultConfigurationId: resolved.defaultRunConfiguration ?? null,
    discoveredJava: discovered.java,
    discoveredMaven: discovered.maven,
    discoveredRuntimes: discovered.runtimes,
    globalToolchain,
    effectiveRuntimeExecutablePaths: effectiveRuntimePaths,
  };
}
