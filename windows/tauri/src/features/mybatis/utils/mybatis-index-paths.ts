import { getBaseName, getRelativePath, normalizePath } from "@/utils/path-helpers";
import type { MybatisIndex } from "../types/mybatis.types";

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

const mapperPathsByIndex = new WeakMap<MybatisIndex, Set<string>>();

/**
 * Whether editing `filePath` can change `index`. Mapper XML always can; a Java
 * file only when it holds a mapper interface the index already pairs. Every
 * other Java edit rebuilt the index from the whole workspace and held up
 * completion on large projects while it ran.
 */
export function editAffectsMybatisIndex(
  filePath: string,
  root: string,
  index: MybatisIndex,
): boolean {
  if (!isMybatisIndexPath(filePath)) return false;
  if (!getBaseName(filePath).toLowerCase().endsWith(".java")) return true;
  let mapperPaths = mapperPathsByIndex.get(index);
  if (!mapperPaths) {
    mapperPaths = new Set(index.statements.map((statement) => statement.javaPath));
    mapperPathsByIndex.set(index, mapperPaths);
  }
  return mapperPaths.has(normalizePath(workspaceRelativeMybatisPath(filePath, root)));
}
