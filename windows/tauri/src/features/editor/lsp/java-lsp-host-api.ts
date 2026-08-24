import { invoke } from "@/platform/tauri-core";

export interface JavaLspLaunch {
  providerId: string;
  languageId: string;
  executablePath: string;
  arguments: string[];
  runtimeExecutablePath?: string | null;
  cacheDirectory: string;
  environment: {
    JAVA_HOME?: string;
  };
  /** Digest of the workspace structure and selected JDT LS version. */
  workspaceFingerprint?: string | null;
}

export function resolveJavaLspLaunch(workspacePath: string) {
  return invoke<JavaLspLaunch>("lsp_resolve_java_launch", {
    workspacePath,
  });
}
