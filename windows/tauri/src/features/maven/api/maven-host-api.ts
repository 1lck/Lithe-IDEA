import { invoke } from "@/platform/tauri-core";
import { inspectRunConfiguration } from "@/features/run/api/run-core-api";
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

/**
 * Resolves the Maven this workspace runs without launching any process.
 *
 * The host applies the same candidate order as a build: the override first,
 * then a usable project wrapper, then a machine installation. It performs no
 * `mvn -version` probe, because this runs on the editor path that blocks Java
 * language-server startup.
 */
export function resolveMavenInstallation(root: string, overridePath?: string) {
  return invoke<string | null>("maven_resolve_installation", { root, overridePath });
}

/**
 * Returns a fresh host-owned file for one dependency session's tree.
 *
 * The session must call `removeMavenDependencyOutput` once it ends, whether
 * the tree was read, cancelled, timed out, or failed.
 */
export function createMavenDependencyOutput(sessionId: string) {
  return invoke<string>("maven_create_dependency_output", { sessionId });
}

export function removeMavenDependencyOutput(sessionId: string) {
  return invoke<void>("maven_remove_dependency_output", { sessionId });
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
export async function resolveMavenEffectiveConfiguration(
  root: string,
  workingDirectory: string,
  settings: MavenSettings,
  dependencies = {
    inspectRunConfiguration,
    resolveConfiguration: (args: MavenSettings & { root: string; workingDirectory: string }) =>
      invoke<MavenEffectiveConfiguration>("maven_resolve_effective_configuration", { args }),
  },
) {
  return dependencies.resolveConfiguration({
    ...settings,
    root,
    workingDirectory,
    javaHomePath: await resolveMavenJavaHome(
      root, settings.javaHomePath, dependencies.inspectRunConfiguration,
    ),
  });
}

/** Both the settings hint and goal launch inherit the same saved project JDK. */
async function resolveMavenJavaHome(
  root: string,
  configured: string | null | undefined,
  inspect = inspectRunConfiguration,
) {
  if (configured?.trim()) return configured.trim();
  try {
    const defaults = (await inspect(root, false)).toolchain;
    return defaults?.maven?.javaHomePath?.trim() || defaults?.java?.homePath?.trim() || "";
  } catch {
    // Run documents are optional for Maven goals. Never log their contents or
    // host paths, and retain the host's normal JDK selection on read failure.
    console.warn(
      "[maven] Project JDK defaults unavailable; using host JDK selection. Repair Run configuration documents in Settings.",
    );
    return "";
  }
}

export async function resolveMavenLaunch(
  root: string,
  context: MavenLaunchContext,
  plan: MavenLaunchPlan,
  dependencies = { inspectRunConfiguration, resolveRunLaunch },
) {
  return dependencies.resolveRunLaunch({
    root,
    executable: plan.executable,
    workingDirectory: plan.workingDirectory,
    javaHomePath: "",
    mavenExecutablePath: context.mavenExecutablePath ?? "",
    mavenJavaHomePath: await resolveMavenJavaHome(
      root, context.javaHomePath, dependencies.inspectRunConfiguration,
    ),
    environment: {},
  });
}

export { startRunProcess as startMavenProcess, stopRunProcess as stopMavenProcess };
