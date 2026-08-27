import type { BackendLanguageToolConfigSet } from "@/extensions/registry/extension-store-runtime";
import { isJavaSourcePath, JAVA_LANGUAGE_ID, JAVA_PROVIDER_ID } from "./built-in-language-support";
import {
  resolveJavaLspLaunch,
  type JdtlsLaunchResources,
} from "./java-lsp-host-api";

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
}

export async function resolveEditorLspLaunch(
  filePath: string,
  workspacePath: string,
): Promise<EditorLspLaunch | null> {
  if (isJavaSourcePath(filePath)) {
    const launch = await resolveJavaLspLaunch(workspacePath);
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
