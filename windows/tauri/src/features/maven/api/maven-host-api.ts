import { invoke } from "@/platform/tauri-core";
import { inspectRunConfiguration } from "@/features/run/api/run-core-api";
import { resolveRunLaunch, startRunProcess, stopRunProcess } from "@/features/run/api/run-host-api";
import type {
  MavenLaunchContext,
  MavenLaunchPlan,
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

export function writeMavenConfiguration(
  root: string,
  reactorPath: string,
  configuration: MavenStoredConfiguration,
) {
  return invoke<void>("maven_write_configuration", {
    args: { root, reactorPath, configuration },
  });
}

export async function resolveMavenLaunch(
  root: string,
  context: MavenLaunchContext,
  plan: MavenLaunchPlan,
  dependencies = { inspectRunConfiguration, resolveRunLaunch },
) {
  let defaults: Awaited<ReturnType<typeof inspectRunConfiguration>>["toolchain"];
  if (!context.javaHomePath) {
    try {
      defaults = (await dependencies.inspectRunConfiguration(root, false)).toolchain;
    } catch {
      // Run documents are optional for Maven goals. Never log their contents or
      // host paths, and retain the host's normal JDK selection on read failure.
      console.warn(
        "[maven] Project JDK defaults unavailable; using host JDK selection. Repair Run configuration documents in Settings.",
      );
    }
  }
  return dependencies.resolveRunLaunch({
    root,
    executable: plan.executable,
    workingDirectory: plan.workingDirectory,
    javaHomePath: "",
    mavenExecutablePath: context.mavenExecutablePath ?? "",
    mavenJavaHomePath:
      context.javaHomePath || defaults?.maven?.javaHomePath || defaults?.java?.homePath || "",
    environment: {},
  });
}

export { startRunProcess as startMavenProcess, stopRunProcess as stopMavenProcess };
