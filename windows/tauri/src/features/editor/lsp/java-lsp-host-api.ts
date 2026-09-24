import { invoke } from "@/platform/tauri-core";

export interface JdtlsLaunchResources {
  launcherJarPath: string;
  configurationDirectory: string;
  lombokAgentPath: string;
  javaDebugBundlePath: string;
  /** Java Test bundles JDT LS loads so it can discover tests. */
  javaExtensionBundlePaths: string[];
}

export interface JavaLspLaunch {
  providerId: string;
  languageId: string;
  executablePath: string;
  arguments: string[];
  runtimeExecutablePath?: string | null;
  jdtlsLaunchResources?: JdtlsLaunchResources | null;
  cacheDirectory: string;
  environment: {
    JAVA_HOME?: string;
  };
  /** Digest of the workspace structure and selected JDT LS version. */
  workspaceFingerprint?: string | null;
  /** Installed JDKs JDT LS may compile projects against. */
  javaRuntimes?: JavaLspRuntime[];
}

export interface JavaLspRuntime {
  homePath: string;
  version: string;
}

export function resolveJavaLspLaunch(workspacePath: string) {
  return invoke<JavaLspLaunch>("lsp_resolve_java_launch", {
    workspacePath,
  });
}
