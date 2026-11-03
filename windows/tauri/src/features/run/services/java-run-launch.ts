import { getJavaWorkspaceLanguageServerOwner } from "@/features/editor/lsp/java-workspace-language-server";
import type { WorkspaceLaunchScope } from "@/features/workspace/types/workspace-launch-scope";
import type { JavaBuildFailure } from "@/platform/java-launch-readiness";
import { invokeLsp } from "@/platform/lsp-core-adapter";
import { createTranslator } from "@/i18n/locale";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { joinPath, normalizePath } from "@/utils/path-helpers";
import type { JavaLaunchTarget, RunConfiguration } from "../types/run.types";

export type JavaRunLaunchPreparation =
  | { kind: "ready"; target: JavaLaunchTarget }
  | { kind: "buildFailed"; target: JavaLaunchTarget; failure: JavaBuildFailure };

/** Returns whether a launch is prepared through the JDT LS project build. */
export function usesJavaProjectPreparation(configuration: RunConfiguration): boolean {
  const isJavaProjectLaunch =
    configuration.provider === "java.main" || configuration.provider === "spring-boot.maven";
  return isJavaProjectLaunch && Boolean(configuration.mavenReactorPath);
}

/** Builds one Java project target and resolves the runtime paths owned by JDT LS. */
export async function prepareJavaRunLaunch(
  scope: WorkspaceLaunchScope,
  configuration: RunConfiguration,
): Promise<JavaRunLaunchPreparation | null> {
  if (!usesJavaProjectPreparation(configuration)) return null;
  if (!configuration.sourcePath || !configuration.mainClass) {
    throw new Error(`The Java source for ${configuration.name} could not be resolved.`);
  }
  const sourcePath = normalizePath(joinPath(scope.root, configuration.sourcePath));
  const preparation = await getJavaWorkspaceLanguageServerOwner().prewarm(scope, sourcePath);
  if (preparation.kind !== "ready") {
    throw new Error(`The Java language service is not ready (${preparation.kind}).`);
  }
  // Core owns the bounded wait for project configuration and earlier builds.
  // Do not reject a launch from a transient presentation snapshot here.
  try {
    const result = await invokeLsp<JavaRunLaunchPreparation>("java_prepare_run_launch", {
      workspacePath: scope.root,
      sourcePath,
      mainClass: configuration.mainClass,
    });
    if (result.kind === "buildFailed") {
      const t = createTranslator(useSettingsStore.getState().settings.displayLanguage);
      return { ...result, failure: { ...result.failure, message: t(result.failure.message) } };
    }
    return result;
  } catch (error) {
    if (error instanceof Error) {
      // Translate Core's catalogued product message, keeping its error code,
      // build evidence and any unknown upstream message unchanged.
      const t = createTranslator(useSettingsStore.getState().settings.displayLanguage);
      error.message = t(error.message);
    }
    throw error;
  }
}
