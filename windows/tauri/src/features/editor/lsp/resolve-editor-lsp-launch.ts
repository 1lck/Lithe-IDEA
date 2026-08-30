import type { BackendLanguageToolConfigSet } from "@/extensions/registry/extension-store-runtime";
import { isJavaSourcePath, JAVA_LANGUAGE_ID, JAVA_PROVIDER_ID } from "./built-in-language-support";
import { resolveJavaLspLaunch, type JdtlsLaunchResources } from "./java-lsp-host-api";
import type { MavenLaunchContext } from "@/features/maven/types/maven.types";
import { mavenLaunchContextForWorkspace } from "@/features/maven/stores/maven.store";
import type { WorkspaceLaunchScope } from "@/features/workspace/types/workspace-launch-scope";
import { getRelativePath } from "@/utils/path-helpers";

export interface EditorLspLaunch {
  providerId: string;
  languageId: string;
  serverPath: string;
  serverArgs: string[];
  initializationOptions?: Record<string, unknown>;
  tools?: BackendLanguageToolConfigSet;
  runtimeExecutablePath?: string | null;
  jdtlsLaunchResources?: JdtlsLaunchResources | null;
  cacheDirectory?: string;
  environment?: Record<string, string>;
  /** Workspace structure digest forwarded to the Rust core. */
  workspaceFingerprint?: string | null;
  mavenContext?: MavenLaunchContext | null;
}

export interface EditorLspLaunchDependencies {
  resolveJavaLspLaunch: typeof resolveJavaLspLaunch;
  mavenLaunchContextForWorkspace: typeof mavenLaunchContextForWorkspace;
}

const defaultDependencies: EditorLspLaunchDependencies = {
  resolveJavaLspLaunch,
  mavenLaunchContextForWorkspace,
};

export async function resolveEditorLspLaunch(
  filePath: string,
  scope: WorkspaceLaunchScope,
  dependencies: EditorLspLaunchDependencies = defaultDependencies,
): Promise<EditorLspLaunch | null> {
  const workspacePath = scope.root;
  if (isJavaSourcePath(filePath)) {
    const [launch, mavenContext] = await Promise.all([
      dependencies.resolveJavaLspLaunch(workspacePath),
      dependencies.mavenLaunchContextForWorkspace(
        workspacePath,
        [getRelativePath(filePath, workspacePath)],
        scope.workspaceId,
      ),
    ]);
    const environment: Record<string, string> = {};
    if (launch.environment.JAVA_HOME) {
      environment.JAVA_HOME = launch.environment.JAVA_HOME;
    }
    return {
      providerId: launch.providerId || JAVA_PROVIDER_ID,
      languageId: launch.languageId || JAVA_LANGUAGE_ID,
      serverPath: launch.executablePath,
      serverArgs: launch.arguments ?? [],
      runtimeExecutablePath: launch.runtimeExecutablePath,
      jdtlsLaunchResources: launch.jdtlsLaunchResources,
      cacheDirectory: launch.cacheDirectory,
      environment,
      workspaceFingerprint: launch.workspaceFingerprint,
      mavenContext,
    };
  }

  const [{ extensionRegistry }, { getLanguageToolConfigSet }] = await Promise.all([
    import("@/extensions/registry/extension-registry"),
    import("@/extensions/registry/extension-store-runtime"),
  ]);
  const extension = extensionRegistry.getExtensionForFilePath(filePath);
  const serverPath = extensionRegistry.getLspServerPath(filePath);
  const languageId = extensionRegistry.getLanguageId(filePath);
  if (!serverPath || !languageId) return null;

  return {
    providerId: languageId,
    languageId,
    serverPath,
    serverArgs: extensionRegistry.getLspServerArgs(filePath),
    initializationOptions: extensionRegistry.getLspInitializationOptions(filePath),
    tools: getLanguageToolConfigSet(extension?.manifest),
  };
}
