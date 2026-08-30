export type RunConfigurationStatus = "missing" | "ready" | "invalid";
export type RunRecoveryAction =
  | "none"
  | "regenerate"
  | "editConfiguration"
  | "fixPermissions"
  | "upgradeApplication";
export type RunSaveScope = "local" | "project";
export type RunConfigurationSource = "generated" | "project" | "local";
export type RunExecution = "application" | "service" | "task" | "group";

export interface RunDiagnostic {
  id?: string;
  code: string;
  message: string;
  toolchain?: string;
}

export interface RunConfiguration {
  id: string;
  name: string;
  provider: string;
  kindTitle: string;
  execution: RunExecution;
  modulePath?: string;
  mainClass?: string;
  cwd: string;
  args: string[];
  env: Record<string, string>;
  jvmArguments: string[];
  programArguments: string[];
  profiles: string[];
  mavenSkipTests: boolean | null;
  javaHomePath: string;
  mavenExecutablePath: string;
  mavenJavaHomePath: string;
  toolchains: Record<string, string>;
  source: RunConfigurationSource;
  disabled: boolean;
}

export interface RunOptions {
  javaHomePath: string;
  mavenExecutablePath: string;
  mavenJavaHomePath: string;
  mavenSkipTests?: boolean | null;
  workingDirectoryPath: string;
  vmArguments: string;
  programArguments: string;
  environment: Record<string, string>;
}

export interface RunSession {
  id: string;
  configurationId: string;
  title: string;
  output: string;
  isRunning: boolean;
  exitCode: number | null;
}

export interface JavaRuntime {
  homePath: string;
  version: string;
  vendor: string;
}

export interface MavenRuntime {
  executablePath: string;
  version: string;
}

export interface GenericRuntime {
  id: string;
  type: string;
  executablePath: string;
  version: string;
  vendor: string;
}

export interface LaunchPlan {
  executable: {
    toolchain?: string | null;
    command?: string | null;
  };
  arguments: string[];
  workingDirectory: string;
  environment?: Record<string, unknown>;
  env?: Record<string, string>;
}

export interface CoreInspectResult {
  status: string;
  diagnostics?: Array<Record<string, string>>;
  localToolchains?: CoreLocalToolchains | null;
}

export interface CoreGenerateResult {
  generated: unknown;
  toolchainRequirements: unknown;
  entryCount: number;
}

export interface CoreResolveResult {
  configurations: CoreResolvedConfiguration[];
  diagnostics?: Array<Record<string, string>>;
  defaultRunConfiguration?: string | null;
  toolchain?: CoreGlobalToolchain | null;
  localToolchains?: CoreLocalToolchains | null;
}

export interface CoreGlobalToolchain {
  java?: { homePath?: string };
  maven?: { executablePath?: string; javaHomePath?: string };
}

export interface CoreLocalToolchains {
  version: number;
  toolchains?: Record<string, { executable?: string }>;
}

export interface GlobalToolchain {
  javaHomePath: string;
  mavenExecutablePath: string;
  mavenJavaHomePath: string;
  runtimeExecutablePaths: Record<string, string>;
}

export interface CoreResolvedConfiguration {
  id: string;
  name: string;
  provider: string;
  execution?: RunExecution | string;
  args?: string[];
  cwd?: string;
  env?: Record<string, string>;
  toolchains?: Record<string, string>;
  source?: string;
  disabled?: boolean;
  extensions?: {
    maven?: {
      module?: string;
      mainClass?: string;
      jvmArguments?: string[];
      programArguments?: string[];
      profiles?: string[];
      skipTests?: boolean;
    };
    java?: {
      homePath?: string;
      mavenExecutablePath?: string;
      mavenJavaHomePath?: string;
    };
  };
}

export const CURRENT_FILE_ID = "current-file";
export const PRIMARY_SESSION_ID = "primary";

export const EMPTY_RUN_OPTIONS: RunOptions = {
  javaHomePath: "",
  mavenExecutablePath: "",
  mavenJavaHomePath: "",
  mavenSkipTests: null,
  workingDirectoryPath: "",
  vmArguments: "",
  programArguments: "",
  environment: {},
};

export const EMPTY_GLOBAL_TOOLCHAIN: GlobalToolchain = {
  javaHomePath: "",
  mavenExecutablePath: "",
  mavenJavaHomePath: "",
  runtimeExecutablePaths: {},
};
