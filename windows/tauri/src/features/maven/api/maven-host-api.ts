import { invoke } from "@/platform/tauri-core";
import { resolveRunLaunch, startRunProcess, stopRunProcess } from "@/features/run/api/run-host-api";
import type {
  MavenEffectiveConfiguration,
  MavenLaunchContext,
  MavenLaunchPlan,
  MavenSettings,
  MavenStoredConfiguration,
} from "../types/maven.types";

export function loadMavenConfiguration(root: string, reactorPath: string) {
  return invoke<MavenStoredConfiguration>("maven_load_configuration", {
    root,
    reactorPath,
  });
}

export function writeMavenConfiguration(
  root: string,
  reactorPath: string,
  configuration: MavenStoredConfiguration,
) {
  return invoke<void>("maven_write_configuration", {
    args: { root, reactorPath, configuration },
  });
}

/**
 * Resolves what a Maven launch would actually use for the given settings, so the
 * configuration surfaces can show what their empty fields fall back to.
 */
export function resolveMavenEffectiveConfiguration(
  root: string,
  workingDirectory: string,
  settings: MavenSettings,
) {
  return invoke<MavenEffectiveConfiguration>("maven_resolve_effective_configuration", {
    args: {
      root,
      workingDirectory,
      settingsPath: settings.settingsPath,
      localRepositoryPath: settings.localRepositoryPath,
      mavenExecutablePath: settings.mavenExecutablePath,
      javaHomePath: settings.javaHomePath,
    },
  });
}

export async function resolveMavenLaunch(
  root: string,
  context: MavenLaunchContext,
  plan: MavenLaunchPlan,
) {
  return resolveRunLaunch({
    root,
    executable: plan.executable,
    workingDirectory: plan.workingDirectory,
    javaHomePath: "",
    mavenExecutablePath: context.mavenExecutablePath ?? "",
    mavenJavaHomePath: context.javaHomePath ?? "",
    environment: {},
  });
}

export { startRunProcess as startMavenProcess, stopRunProcess as stopMavenProcess };
