import { invoke } from "@/platform/tauri-core";
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
