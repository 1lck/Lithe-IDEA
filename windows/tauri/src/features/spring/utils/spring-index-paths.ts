import { getBaseName, getRelativePath, normalizePath } from "@/utils/path-helpers";

export function isSpringIndexPath(filePath: string): boolean {
  const name = getBaseName(filePath).toLowerCase();
  if (name.endsWith(".java")) return true;
  if (name === "spring-configuration-metadata.json") return true;
  if (name === "additional-spring-configuration-metadata.json") return true;
  return isSpringConfigurationPath(filePath);
}

export function isSpringConfigurationPath(filePath: string): boolean {
  const name = getBaseName(filePath).toLowerCase();
  if (name === "application.properties") return true;
  if (name.startsWith("application-") && name.endsWith(".properties")) return true;
  if (name === "application.yml" || name === "application.yaml") return true;
  return name.startsWith("application-") && (name.endsWith(".yml") || name.endsWith(".yaml"));
}

export function workspaceRelativeSpringPath(filePath: string, root: string): string {
  return getRelativePath(filePath, root).replace(/\\/g, "/");
}

export function collectSpringIndexPaths(filePaths: readonly string[], root: string): string[] {
  const paths = new Set<string>();
  for (const filePath of filePaths) {
    if (!isSpringIndexPath(filePath)) continue;
    const relative = workspaceRelativeSpringPath(filePath, root);
    if (relative) paths.add(normalizePath(relative));
  }
  return [...paths].sort();
}
