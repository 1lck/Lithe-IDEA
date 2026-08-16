import { executeCore } from "@/core/lithe-core-client";
import type {
  CoreGenerateResult,
  CoreInspectResult,
  CoreResolveResult,
  LaunchPlan,
  RunOptions,
  RunSaveScope,
} from "../types/run.types";

let requestSequence = 0;

function nextRequestId(prefix: string): string {
  requestSequence += 1;
  return `${prefix}-${Date.now()}-${requestSequence}`;
}

async function runCore<T>(command: string, payload: unknown, timeoutMilliseconds = 30_000): Promise<T> {
  const response = await executeCore<T>(
    {
      id: nextRequestId(command),
      operationId: nextRequestId(`${command}-op`),
      timeoutMilliseconds,
      command,
      payload,
    },
  );
  if (!response.ok) {
    const error = new Error(response.error.message) as Error & { code?: string };
    error.code = response.error.code;
    throw error;
  }
  return response.data;
}

export function inspectRunConfiguration(root: string) {
  return runCore<CoreInspectResult>("runConfig.inspect", { root });
}

export function generateRunConfiguration(root: string, paths: string[], modulePaths: string[] = []) {
  return runCore<CoreGenerateResult>(
    "runConfig.generate",
    { root, paths, modulePaths },
    60_000,
  );
}

export function resolveRunConfiguration(
  root: string,
  toolchainCandidates: Array<{ id: string; type: string; version: string; vendor: string }>,
) {
  return runCore<CoreResolveResult>("runConfig.resolve", { root, toolchainCandidates });
}

export function createLaunchPlan(
  root: string,
  configurationId: string,
  currentFile?: string,
) {
  return runCore<LaunchPlan>("runConfig.createLaunchPlan", {
    root,
    configurationId,
    currentFile,
  });
}

export function updateRunOptions(
  root: string,
  configurationId: string,
  scope: RunSaveScope,
  options: RunOptions,
) {
  return runCore<{ document: string }>("runConfig.updateOptions", {
    root,
    scope,
    configurationId,
    workingDirectory: options.workingDirectoryPath,
    jvmArguments: options.vmArguments,
    arguments: options.programArguments,
    environment: options.environment,
    mavenProfiles: [],
    javaHomePath: scope === "local" ? options.javaHomePath : "",
    mavenExecutablePath: scope === "local" ? options.mavenExecutablePath : "",
    mavenJavaHomePath: scope === "local" ? options.mavenJavaHomePath : "",
  });
}
