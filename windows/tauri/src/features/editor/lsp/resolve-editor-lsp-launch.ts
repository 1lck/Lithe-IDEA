import type { BackendLanguageToolConfigSet } from "@/extensions/registry/extension-store-runtime";
import { resolveDeclarativePluginLaunch } from "@/features/plugins/declarative-plugin-launch";
import { isJavaSourcePath, JAVA_LANGUAGE_ID, JAVA_PROVIDER_ID } from "./built-in-language-support";
import {
  resolveJavaLspLaunch,
  type JavaLspRuntime,
  type JavaLspGradle,
  type JdtlsLaunchResources,
} from "./java-lsp-host-api";
import { mavenLaunchContextForWorkspace } from "@/features/maven/stores/maven.store";
import type { WorkspaceLaunchScope } from "@/features/workspace/types/workspace-launch-scope";
import { getRelativePath } from "@/utils/path-helpers";
import { ensureWorkspaceGitBootstrap } from "@/features/workspace/services/workspace-git-bootstrap";
import {
  prepareBuildLanguageImport,
  bindJavaBuildLanguageImport,
  type MavenLanguageImportContext,
} from "@/features/build-systems/build-language-import";

export interface EditorLspLaunch {
  providerId: string;
  pluginId?: string;
  languageId: string;
  serverPath: string;
  serverArgs: string[];
  initializationOptions?: Record<string, unknown>;
  workspaceConfiguration?: Record<string, unknown>;
  tools?: BackendLanguageToolConfigSet;
  runtimeExecutablePath?: string | null;
  jdtlsLaunchResources?: JdtlsLaunchResources | null;
  cacheDirectory?: string;
  environment?: Record<string, string>;
  /** Workspace structure digest forwarded to the Rust core. */
  workspaceFingerprint?: string | null;
  mavenContext?: MavenLanguageImportContext | null;
  javaRuntimes?: JavaLspRuntime[];
  /** Gradle import context forwarded to the Rust core. */
  javaGradle?: JavaLspGradle | null;
}

export interface EditorLspLaunchDependencies {
  prepareBuildLanguageImport?: typeof prepareBuildLanguageImport;
  ensureWorkspaceGitBootstrap: typeof ensureWorkspaceGitBootstrap;
  resolveJavaLspLaunch: typeof resolveJavaLspLaunch;
  mavenLaunchContextForWorkspace: typeof mavenLaunchContextForWorkspace;
  resolveDeclarativePluginLaunch: typeof resolveDeclarativePluginLaunch;
}

const defaultDependencies: EditorLspLaunchDependencies = {
  prepareBuildLanguageImport,
  ensureWorkspaceGitBootstrap,
  resolveJavaLspLaunch,
  mavenLaunchContextForWorkspace,
  resolveDeclarativePluginLaunch,
};

export async function resolveEditorLspLaunch(
  filePath: string,
  scope: WorkspaceLaunchScope,
  dependencies: EditorLspLaunchDependencies = defaultDependencies,
): Promise<EditorLspLaunch | null> {
  const workspacePath = scope.root;
  if (isJavaSourcePath(filePath)) {
    // Restored documents can attach before background prewarm runs. Both entry
    // points must wait before Maven discovery or JDTLS preparation starts.
    if ((await dependencies.ensureWorkspaceGitBootstrap(scope)) === "superseded") return null;
    const prepared = await dependencies.prepareBuildLanguageImport?.(scope, filePath);
    try {
      const [launch, legacyMavenContext] = await Promise.all([
        dependencies.resolveJavaLspLaunch(workspacePath),
        prepared?.value.mavenContext
          ? Promise.resolve(null)
          : dependencies.mavenLaunchContextForWorkspace(
              workspacePath,
              [getRelativePath(filePath, workspacePath)],
              scope.workspaceId,
            ),
      ]);
      // Startup preparation and legacy model reads may yield. Recheck options,
      // model, package bytes and workspace before returning anything to JDT.
      await prepared?.validate();
      prepared?.assertCurrent();
      const environment: Record<string, string> = {};
      if (launch.environment.JAVA_HOME) {
        environment.JAVA_HOME = launch.environment.JAVA_HOME;
      }
      if (prepared)
        bindJavaBuildLanguageImport(scope, filePath, prepared.value.mavenContext !== null);
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
        mavenContext: prepared?.value.mavenContext ?? legacyMavenContext,
        javaRuntimes: launch.javaRuntimes ?? [],
        javaGradle: prepared?.value.javaGradle ?? launch.javaGradle ?? null,
      };
    } finally {
      prepared?.dispose();
    }
  }

  const [{ extensionRegistry }, { getLanguageToolConfigSet }] = await Promise.all([
    import("@/extensions/registry/extension-registry"),
    import("@/extensions/registry/extension-store-runtime"),
  ]);
  const extension = extensionRegistry.getExtensionForFilePath(filePath);
  const serverPath = extensionRegistry.getLspServerPath(filePath);
  const languageId = extensionRegistry.getLanguageId(filePath);
  if (!serverPath || !languageId) {
    return resolveDeclarativeFallback(filePath, workspacePath, dependencies);
  }

  return {
    providerId: languageId,
    languageId,
    serverPath,
    serverArgs: extensionRegistry.getLspServerArgs(filePath),
    initializationOptions: extensionRegistry.getLspInitializationOptions(filePath),
    tools: getLanguageToolConfigSet(extension?.manifest),
  };
}

/**
 * Contract v1 declarative plugins resolve after the Worker extension model so
 * a Worker-owned language keeps its server until the package migration lands.
 */
async function resolveDeclarativeFallback(
  filePath: string,
  workspacePath: string,
  dependencies: EditorLspLaunchDependencies,
): Promise<EditorLspLaunch | null> {
  const launch = await dependencies.resolveDeclarativePluginLaunch(filePath, workspacePath);
  if (!launch) return null;
  return {
    providerId: launch.pluginId,
    pluginId: launch.pluginId,
    languageId: launch.languageId,
    serverPath: launch.serverPath,
    serverArgs: launch.serverArgs,
    initializationOptions: launch.initializationOptions ?? undefined,
    workspaceConfiguration: launch.workspaceConfiguration ?? undefined,
    environment: launch.environment,
  };
}
