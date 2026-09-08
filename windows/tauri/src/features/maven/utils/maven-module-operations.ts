import type { RunConfiguration } from "@/features/run/types/run.types";

export type MavenModuleExecutionMode = "run" | "debug";

function normalizedPath(value: string | undefined): string {
  const normalized = (value ?? ".").trim().replace(/\\/g, "/").replace(/^\.\//, "");
  return normalized.replace(/\/+$/, "") || ".";
}

function eligibleConfiguration(
  configuration: RunConfiguration,
  mode: MavenModuleExecutionMode,
): boolean {
  if (configuration.disabled || !["application", "service"].includes(configuration.execution)) {
    return false;
  }
  return mode === "run" || configuration.debugAdapter === "jdwp";
}

function selectUnambiguousConfiguration(
  configurations: RunConfiguration[],
): RunConfiguration | null {
  if (configurations.length === 1) return configurations[0];

  const services = configurations.filter((configuration) => configuration.execution === "service");
  if (services.length === 1) return services[0];

  const applications = configurations.filter(
    (configuration) => configuration.execution === "application",
  );
  return applications.length === 1 ? applications[0] : null;
}

export function findMavenModuleRunConfiguration(args: {
  configurations: RunConfiguration[];
  defaultConfigurationId: string | null;
  projectRelativePath: string;
  moduleRelativePath: string;
  mode: MavenModuleExecutionMode;
}): RunConfiguration | null {
  const modulePath = normalizedPath(args.moduleRelativePath);
  const candidates = args.configurations.filter(
    (configuration) =>
      eligibleConfiguration(configuration, args.mode) &&
      normalizedPath(configuration.modulePath) === modulePath,
  );
  if (candidates.length === 0) return null;

  const configuredDefault = candidates.find(
    (configuration) => configuration.id === args.defaultConfigurationId,
  );
  if (configuredDefault) return configuredDefault;

  const reactorPath = normalizedPath(args.projectRelativePath);
  const reactorCandidates = candidates.filter(
    (configuration) => normalizedPath(configuration.cwd) === reactorPath,
  );
  return selectUnambiguousConfiguration(
    reactorCandidates.length > 0 ? reactorCandidates : candidates,
  );
}

export function findMavenModuleJavaPath(
  visiblePaths: string[],
  projectRelativePath: string,
  moduleRelativePath: string,
): string | null {
  const projectPath = normalizedPath(projectRelativePath);
  const modulePath = normalizedPath(moduleRelativePath);
  const targetPath = [projectPath, modulePath]
    .filter((path) => path !== ".")
    .join("/")
    .toLowerCase();
  return (
    visiblePaths
      .map((path) => normalizedPath(path))
      .filter((path) => path.toLowerCase().endsWith(".java"))
      .filter(
        (path) =>
          !targetPath ||
          path.toLowerCase() === targetPath ||
          path.toLowerCase().startsWith(`${targetPath}/`),
      )
      .sort((left, right) => left.localeCompare(right))[0] ?? null
  );
}
