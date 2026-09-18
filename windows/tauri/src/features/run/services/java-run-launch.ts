import { getJavaWorkspaceLanguageServerOwner } from "@/features/editor/lsp/java-workspace-language-server";
import type { WorkspaceLaunchScope } from "@/features/workspace/types/workspace-launch-scope";
import { invokeLsp } from "@/platform/lsp-core-adapter";
import { joinPath } from "@/utils/path-helpers";
import type { JavaLaunchTarget, RunConfiguration } from "../types/run.types";

/** Builds one Java project target and resolves the runtime paths owned by JDT LS. */
export async function prepareJavaRunLaunch(
  scope: WorkspaceLaunchScope,
  configuration: RunConfiguration,
): Promise<JavaLaunchTarget | null> {
  if (configuration.provider !== "java.main" || !configuration.mavenReactorPath) return null;
  if (!configuration.sourcePath || !configuration.mainClass) {
    throw new Error(`The Java source for ${configuration.name} could not be resolved.`);
  }
  const sourcePath = joinPath(scope.root, configuration.sourcePath);
  const preparation = await getJavaWorkspaceLanguageServerOwner().prewarm(scope, sourcePath);
  if (preparation.kind !== "ready") {
    throw new Error(`The Java language service is not ready (${preparation.kind}).`);
  }
  return invokeLsp<JavaLaunchTarget>("java_prepare_run_launch", {
    workspacePath: scope.root,
    sourcePath,
    mainClass: configuration.mainClass,
  });
}
