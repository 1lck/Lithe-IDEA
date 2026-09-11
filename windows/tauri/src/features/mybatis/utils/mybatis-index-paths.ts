import { getBaseName, getRelativePath, normalizePath } from "@/utils/path-helpers";

export function isMybatisIndexPath(filePath: string): boolean {
  const name = getBaseName(filePath).toLowerCase();
  if (name.endsWith(".java")) return true;
  return name.endsWith(".xml") && name !== "pom.xml";
}

export function workspaceRelativeMybatisPath(filePath: string, root: string): string {
  return getRelativePath(filePath, root).replace(/\\/g, "/");
}

export function collectMybatisIndexPaths(filePaths: readonly string[], root: string): string[] {
  const paths = new Set<string>();
  for (const filePath of filePaths) {
    if (!isMybatisIndexPath(filePath)) continue;
    const relative = workspaceRelativeMybatisPath(filePath, root);
    if (relative) paths.add(normalizePath(relative));
  }
  return [...paths].sort();
}
