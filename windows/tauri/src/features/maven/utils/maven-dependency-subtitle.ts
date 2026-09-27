import type { MavenDependency } from "../types/maven.types";

type Translate = (key: string, values?: Record<string, string | number>) => string;

/**
 * Describes one dependency row: its coordinate, scope, and Maven's verbose
 * annotations in the order `dependency:tree` prints them.
 */
export function mavenDependencySubtitle(dependency: MavenDependency, t: Translate): string {
  const resolution =
    dependency.resolution === "omittedConflict"
      ? `${t("maven.omittedConflict")}${dependency.selectedVersion ? ` -> ${dependency.selectedVersion}` : ""}`
      : dependency.resolution === "omittedDuplicate"
        ? t("maven.omittedDuplicate")
        : null;
  const markers = [
    dependency.premanagedVersion
      ? t("maven.versionManagedFrom", { value: dependency.premanagedVersion })
      : null,
    dependency.premanagedScope
      ? t("maven.scopeManagedFrom", { value: dependency.premanagedScope })
      : null,
    dependency.originalScope ? t("maven.scopeUpdatedFrom", { value: dependency.originalScope }) : null,
    dependency.ignoredScope ? t("maven.scopeNotUpdatedTo", { value: dependency.ignoredScope }) : null,
    resolution,
  ].filter((marker) => marker !== null);
  const classifier = dependency.classifier ? `:${dependency.classifier}` : "";
  const annotations = markers.length > 0 ? ` (${markers.join("; ")})` : "";
  return `${dependency.groupId}:${dependency.version}:${dependency.type}${classifier} [${dependency.scope}]${annotations}`;
}
