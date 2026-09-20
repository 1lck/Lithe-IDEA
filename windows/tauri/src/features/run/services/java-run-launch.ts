import { getProjectPreparation } from "../stores/project-preparation.store";
import { getJavaWorkspaceLanguageServerOwner } from "@/features/editor/lsp/java-workspace-language-server";
import type { WorkspaceLaunchScope } from "@/features/workspace/types/workspace-launch-scope";
import { invokeLsp } from "@/platform/lsp-core-adapter";
import { joinPath, normalizePath } from "@/utils/path-helpers";
import type { JavaLaunchTarget, RunConfiguration } from "../types/run.types";

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
): Promise<JavaLaunchTarget | null> {
  if (!usesJavaProjectPreparation(configuration)) return null;
  if (!configuration.sourcePath || !configuration.mainClass) {
    throw new Error(`The Java source for ${configuration.name} could not be resolved.`);
  }
  const sourcePath = normalizePath(joinPath(scope.root, configuration.sourcePath));
  const preparation = await getJavaWorkspaceLanguageServerOwner().prewarm(scope, sourcePath);
  if (preparation.kind !== "ready") {
    throw new Error(`The Java language service is not ready (${preparation.kind}).`);
  }
  const project = getProjectPreparation(scope.root);
  if (project?.blocksRun) {
    throw new Error(project.status === "failed"
      ? "Java project preparation failed. Open language service settings to retry."
      : "The Java project is still being prepared. View project preparation progress and run again when it is ready.");
  }
  return invokeLsp<JavaLaunchTarget>("java_prepare_run_launch", {
    workspacePath: scope.root,
    sourcePath,
    mainClass: configuration.mainClass,
  });
}
