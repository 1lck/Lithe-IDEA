import type { JavaEntrypoints } from "@/platform/lsp-core-adapter";
import { executeCore } from "@/core/lithe-core-client";
import type {
  CoreGenerateResult,
  CoreInspectResult,
  CoreResolveResult,
  GlobalToolchain,
  LaunchPlan,
  JavaLaunchTarget,
  RunOptions,
  RunSaveScope,
} from "../types/run.types";
import type { MavenLaunchContext } from "@/features/maven/types/maven.types";
import { projectScopedPath } from "../utils/run-configuration";

let requestSequence = 0;

function nextRequestId(prefix: string): string {
  requestSequence += 1;
  return `${prefix}-${Date.now()}-${requestSequence}`;
}

async function runCore<T>(
  command: string,
  payload: unknown,
  timeoutMilliseconds = 30_000,
): Promise<T> {
  const response = await executeCore<T>({
    id: nextRequestId(command),
    operationId: nextRequestId(`${command}-op`),
    timeoutMilliseconds,
    command,
    payload,
  });
  if (!response.ok) {
    const error = new Error(response.error.message) as Error & { code?: string };
    error.code = response.error.code;
    throw error;
  }
  return response.data;
}

/**
 * Validates run documents. `javaEntrypoints` is JDT's current answer; when
 * given, Core also reports whether the generated Java entries still match it.
 */
export function inspectRunConfiguration(
  root: string,
  checkFingerprint = true,
  javaEntrypoints?: JavaEntrypoints,
) {
  return runCore<CoreInspectResult>("runConfig.inspect", {
    root,
    checkFingerprint,
    ...(javaEntrypoints ? { javaEntrypoints } : {}),
  });
}

/** Updates only machine-local project defaults, even before configurations exist. */
export function updateProjectToolchain(root: string, toolchain: GlobalToolchain) {
  return runCore<{ document: string }>("runConfig.updateOptions", {
    root,
    scope: "local",
    configurationId: "",
    toolchain,
  });
}

/**
 * Regenerates `.lithe/run/generated.json`. `javaEntrypoints` is JDT's current
 * answer; omit it while the Java service is preparing the project and Core
 * keeps the previous generation's Java entries.
 */
export function generateRunConfiguration(
  root: string,
  paths: string[],
  modulePaths: string[] = [],
  javaEntrypoints?: JavaEntrypoints,
) {
  return runCore<CoreGenerateResult>(
    "runConfig.generate",
    javaEntrypoints ? { root, paths, modulePaths, javaEntrypoints } : { root, paths, modulePaths },
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
  mavenContext?: MavenLaunchContext | null,
  debugPort?: number,
  javaLaunch?: JavaLaunchTarget | null,
) {
  return runCore<LaunchPlan>("runConfig.createLaunchPlan", {
    root,
    configurationId,
    currentFile,
    mavenContext: mavenContext ?? null,
    debugPort,
    javaLaunch: javaLaunch
      ? {
          mainClass: javaLaunch.mainClass,
          classPaths: javaLaunch.classPaths,
          modulePaths: javaLaunch.modulePaths,
        }
      : null,
  });
}

export function saveRunConfigurationEditorChanges(
  root: string,
  configurationId: string,
  scope: RunSaveScope,
  options: RunOptions,
  toolchain: GlobalToolchain,
) {
  return runCore<{
    localDocument: string;
    projectDocument: string | null;
    toolchainDocument: string | null;
  }>(
    "runConfig.saveEditorChanges",
    {
      root,
      scope,
      configurationId,
      ...scopedRunOptions(root, scope, options),
      toolchain,
    },
  );
}

function scopedRunOptions(root: string, scope: RunSaveScope, options: RunOptions) {
  const workingDirectory = !options.workingDirectoryPath.trim()
    ? ""
    : scope === "project"
      ? projectScopedPath(root, options.workingDirectoryPath)
      : options.workingDirectoryPath;
  const scopedToolchainPath = (value: string) => {
    if (scope !== "project" || !value.trim()) return value;
    return projectScopedPath(root, value);
  };
  const javaHomePath = scopedToolchainPath(options.javaHomePath);
  const mavenExecutablePath = scopedToolchainPath(options.mavenExecutablePath);
  const mavenJavaHomePath = scopedToolchainPath(options.mavenJavaHomePath);
  if (
    workingDirectory === undefined ||
    javaHomePath === undefined ||
    mavenExecutablePath === undefined ||
    mavenJavaHomePath === undefined
  ) {
    throw new Error("Project paths must stay inside the workspace.");
  }
  return {
    workingDirectory,
    jvmArguments: options.vmArguments,
    arguments: options.programArguments,
    environment: options.environment,
    mavenProfiles: [],
    mavenSkipTests: options.mavenSkipTests ?? null,
    javaHomePath,
    mavenExecutablePath,
    mavenJavaHomePath,
  };
}
