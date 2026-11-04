import { createTranslator } from "@/i18n/locale";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { inspectRunConfiguration } from "@/features/run/api/run-core-api";
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
  /** Gradle import context, present only for Gradle workspaces. */
  javaGradle?: JavaLspGradle | null;
}

export interface JavaLspRuntime {
  isDefault?: boolean;
  homePath: string;
  version: string;
}

export interface JavaLspGradle {
  /** The workspace root ships `gradle/wrapper/gradle-wrapper.properties`. */
  wrapperPresent: boolean;
}

export async function resolveJavaLspLaunch(workspacePath: string) {
  const configuration = await inspectRunConfiguration(workspacePath, false);
  return invoke<JavaLspLaunch>("lsp_resolve_java_launch", {
    workspacePath,
    projectJavaHome: configuration.toolchain?.java?.homePath ?? "",
  }).catch((error: unknown) => {
    if ((error instanceof Error ? error.message : error) === "PROJECT_JDK_INVALID") {
      const t = createTranslator(useSettingsStore.getState().settings.displayLanguage);
      throw new Error(t("lsp.projectJdkInvalid"));
    }
    throw error;
  });
}
