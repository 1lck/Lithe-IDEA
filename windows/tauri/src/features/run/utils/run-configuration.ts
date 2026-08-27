import {
  CURRENT_FILE_ID,
  type CoreGlobalToolchain,
  type CoreLocalToolchains,
  type GenericRuntime,
  type CoreResolvedConfiguration,
  type GlobalToolchain,
  type JavaRuntime,
  type MavenRuntime,
  type RunConfiguration,
  type RunDiagnostic,
  type RunExecution,
  type RunOptions,
  type RunRecoveryAction,
} from "../types/run.types";

const FRAMEWORK_TITLES: Record<string, string> = {
  "spring-boot.maven": "Spring Boot",
  "quarkus.maven": "Quarkus",
  "micronaut.maven": "Micronaut",
  "java.main": "Java Application",
  "java.current-file": "Current File",
  "maven.module": "Maven Module",
};

export function mapCoreConfiguration(value: CoreResolvedConfiguration): RunConfiguration {
  const maven = value.extensions?.maven;
  const java = value.extensions?.java;
  const source = value.source === "project" || value.source === "local" ? value.source : "generated";
  return {
    id: value.id,
    name: value.name,
    provider: value.provider,
    kindTitle: configurationTitle(value.provider),
    execution: normalizeExecution(value.execution, value.provider),
    toolchains: value.toolchains ?? {},
    modulePath: maven?.module && maven.module !== "." ? maven.module : undefined,
    mainClass: maven?.mainClass,
    cwd: value.cwd && value.cwd !== "." ? value.cwd : "",
    args: value.args ?? [],
    env: value.env ?? {},
    jvmArguments: maven?.jvmArguments ?? [],
    programArguments: maven?.programArguments ?? value.args ?? [],
    profiles: maven?.profiles ?? [],
    javaHomePath: java?.homePath ?? "",
    mavenExecutablePath: java?.mavenExecutablePath ?? "",
    mavenJavaHomePath: java?.mavenJavaHomePath ?? "",
    source,
    disabled: Boolean(value.disabled),
  };
}

export function configurationTitle(provider: string): string {
  if (FRAMEWORK_TITLES[provider]) return FRAMEWORK_TITLES[provider];
  const namespace = provider.split(".")[0] ?? provider;
  return namespace.charAt(0).toUpperCase() + namespace.slice(1);
}

export function normalizeExecution(execution: string | undefined, provider: string): RunExecution {
  if (execution === "service" || execution === "application" || execution === "task" || execution === "group") {
    return execution;
  }
  if (provider.endsWith(".maven") && provider !== "maven.module") return "service";
  if (provider === "maven.module") return "task";
  return "application";
}

export function mapCoreToolchain(
  toolchain: CoreGlobalToolchain | null | undefined,
  localToolchains?: CoreLocalToolchains | null,
): GlobalToolchain {
  const runtimeExecutablePaths = Object.fromEntries(
    Object.entries(localToolchains?.toolchains ?? {})
      .filter((entry): entry is [string, { executable: string }] => Boolean(entry[1].executable))
      .map(([id, value]) => [id, value.executable]),
  );
  return {
    javaHomePath: toolchain?.java?.homePath ?? "",
    mavenExecutablePath: toolchain?.maven?.executablePath ?? "",
    mavenJavaHomePath: toolchain?.maven?.javaHomePath ?? "",
    runtimeExecutablePaths,
  };
}

export function runnableConfigurations(configurations: RunConfiguration[]): RunConfiguration[] {
  return configurations.filter((configuration) => configuration.id !== CURRENT_FILE_ID);
}

export function configurationsForExecution(
  configurations: RunConfiguration[],
  execution: RunExecution,
): RunConfiguration[] {
  return runnableConfigurations(configurations)
    .filter((configuration) => configuration.execution === execution)
    .sort((left, right) => left.name.localeCompare(right.name, undefined, { sensitivity: "base" }));
}

export function isBlockingToolchainDiagnostic(diagnostic: RunDiagnostic): boolean {
  return diagnostic.code === "missingToolchain" || diagnostic.code === "toolchainVersionMismatch";
}

export function blockingToolchainDiagnosticForConfiguration(
  diagnostics: RunDiagnostic[],
  configurationId: string | null | undefined,
): RunDiagnostic | undefined {
  return diagnostics.find(
    (diagnostic) =>
      isBlockingToolchainDiagnostic(diagnostic) &&
      (diagnostic.id === undefined || diagnostic.id === configurationId),
  );
}

export function recoveryActionForError(code: string | undefined): RunRecoveryAction {
  switch (code) {
    case "not_supported":
      return "upgradeApplication";
    case "parse_failed":
      return "editConfiguration";
    case "permission_denied":
      return "fixPermissions";
    default:
      return "regenerate";
  }
}

export function recoveryPathFromMessage(message: string): string | undefined {
  return [
    ".lithe/run/generated.json",
    ".lithe/run/configurations.json",
    ".lithe/run/local.json",
    ".lithe/toolchains/requirements.json",
    ".lithe/project.json",
  ].find((path) => message.includes(path));
}

export function defaultGeneratedConfigurationId(generated: unknown): string | undefined {
  const configurations = Array.isArray((generated as { configurations?: unknown[] } | null)?.configurations)
    ? ((generated as { configurations: Array<{ id?: string; provider?: string }> }).configurations)
    : [];
  const framework = configurations.find((configuration) =>
    ["spring-boot.maven", "quarkus.maven", "micronaut.maven"].includes(configuration.provider ?? ""),
  );
  return framework?.id ?? configurations.find((configuration) => configuration.id !== CURRENT_FILE_ID)?.id;
}

export function workspaceRelativePath(root: string, filePath: string): string | undefined {
  const normalizedRoot = root.replace(/[\\/]+$/, "").replace(/\\/g, "/");
  const normalizedFile = filePath.replace(/\\/g, "/");
  if (normalizedFile.toLowerCase() === normalizedRoot.toLowerCase()) {
    return ".";
  }
  if (!normalizedFile.toLowerCase().startsWith(normalizedRoot.toLowerCase() + "/")) {
    return undefined;
  }
  return normalizedFile.slice(normalizedRoot.length + 1);
}

export function projectScopedPath(root: string, value: string): string | undefined {
  const trimmed = value.trim();
  if (!trimmed) return ".";
  const relative = workspaceRelativePath(root, trimmed);
  if (relative !== undefined) return relative;
  if (isAbsolutePath(trimmed)) return undefined;
  return trimmed.replace(/\\/g, "/");
}

function isAbsolutePath(value: string): boolean {
  return /^[A-Za-z]:[\\/]/.test(value) || value.startsWith("/") || value.startsWith("\\\\");
}

export function configurationUsesMaven(configuration: { toolchains?: Record<string, string> }): boolean {
  return Boolean(configuration.toolchains?.maven);
}

export function configurationUsesJava(configuration: { toolchains?: Record<string, string> }): boolean {
  return Boolean(configuration.toolchains?.java || configuration.toolchains?.maven);
}

export function configurationUsesNode(configuration: { toolchains?: Record<string, string> }): boolean {
  return configuration.toolchains?.runtime === "project-node";
}

export function configurationOverrides(
  options: RunOptions,
  defaults: GlobalToolchain,
): RunOptions {
  return {
    ...options,
    javaHomePath: sameWindowsPath(options.javaHomePath, defaults.javaHomePath)
      ? ""
      : options.javaHomePath,
    mavenExecutablePath: sameWindowsPath(
      options.mavenExecutablePath,
      defaults.mavenExecutablePath,
    )
      ? ""
      : options.mavenExecutablePath,
    mavenJavaHomePath: sameWindowsPath(options.mavenJavaHomePath, defaults.mavenJavaHomePath)
      ? ""
      : options.mavenJavaHomePath,
  };
}

export function selectedToolchainCandidates(
  discovered: { java: JavaRuntime[]; maven: MavenRuntime[]; runtimes: GenericRuntime[] },
  selected: GlobalToolchain,
): Array<{ id: string; type: string; version: string; vendor: string }> {
  const java = selected.javaHomePath
    ? discovered.java.find((runtime) => sameWindowsPath(runtime.homePath, selected.javaHomePath))
    : discovered.java[0];
  const maven = selected.mavenExecutablePath
    ? discovered.maven.find((runtime) => mavenSelectionMatchesRuntime(
        selected.mavenExecutablePath,
        runtime.executablePath,
      ))
    : discovered.maven[0];
  const effectiveRuntimePaths = effectiveRuntimeExecutablePaths(
    discovered.runtimes,
    selected.runtimeExecutablePaths,
  );
  const runtimes = Object.entries(effectiveRuntimePaths).flatMap(([id, executablePath]) => {
    const runtime = discovered.runtimes.find(
      (candidate) => candidate.id === id && sameWindowsPath(candidate.executablePath, executablePath),
    );
    return runtime
      ? [{ id: runtime.id, type: runtime.type, version: runtime.version, vendor: runtime.vendor }]
      : [];
  });
  return [
    ...(java ? [{ id: "project-jdk", type: "java", version: java.version, vendor: java.vendor }] : []),
    ...(maven ? [{ id: "project-maven", type: "maven", version: maven.version, vendor: "" }] : []),
    ...runtimes,
  ];
}

export function effectiveRuntimeExecutablePaths(
  discovered: GenericRuntime[],
  configured: Record<string, string>,
): Record<string, string> {
  const runtimeIds = new Set(discovered.map((runtime) => runtime.id));
  return Object.fromEntries(
    [...runtimeIds].flatMap((id) => {
      const configuredPath = configured[id];
      const runtime = configuredPath
        ? discovered.find(
            (candidate) =>
              candidate.id === id && sameWindowsPath(candidate.executablePath, configuredPath),
          )
        : discovered.find((candidate) => candidate.id === id);
      return runtime ? [[id, runtime.executablePath]] : [];
    }),
  );
}

function mavenSelectionMatchesRuntime(selection: string, executable: string): boolean {
  if (sameWindowsPath(selection, executable)) return true;
  const home = selection.replace(/[\\/]+$/, "");
  return ["mvn.cmd", "mvn.bat", "mvn.exe", "mvn"].some((name) =>
    sameWindowsPath(`${home}/bin/${name}`, executable));
}

function sameWindowsPath(left: string, right: string): boolean {
  if (!left || !right) return false;
  const normalize = (value: string) => value.replace(/\\/g, "/").replace(/\/+$/, "").toLowerCase();
  return normalize(left) === normalize(right);
}

export function environmentText(environment: Record<string, string>): string {
  return Object.entries(environment)
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([key, value]) => `${key}=${value}`)
    .join("\n");
}

export function environmentFromText(text: string): Record<string, string> {
  const environment: Record<string, string> = {};
  for (const line of text.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const separator = trimmed.indexOf("=");
    if (separator <= 0) continue;
    environment[trimmed.slice(0, separator)] = trimmed.slice(separator + 1);
  }
  return environment;
}

export function mergeLaunchEnvironment(
  configurationEnv: Record<string, string>,
  plan: { environment?: Record<string, unknown>; env?: Record<string, string> },
): Record<string, unknown> {
  return {
    ...configurationEnv,
    ...(plan.env ?? {}),
    ...(plan.environment ?? {}),
  };
}

export function joinArguments(values: string[]): string {
  return values.join(" ");
}

export function mapDiagnostics(values: Array<Record<string, string>> | undefined): RunDiagnostic[] {
  return (values ?? [])
    .filter((value) => value.code && value.message)
    .map((value) => ({
      id: value.id,
      code: value.code,
      message: value.message,
      toolchain: value.toolchain,
    }));
}
