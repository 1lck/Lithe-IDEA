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
}

export function resolveJavaLspLaunch(workspacePath: string, javaHomePath?: string) {
  return invoke<JavaLspLaunch>("lsp_resolve_java_launch", {
    workspacePath,
    javaHomePath: javaHomePath ?? null,
  });
}
