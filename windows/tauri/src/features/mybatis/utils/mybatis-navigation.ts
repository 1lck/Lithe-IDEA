import { joinPath, normalizePath } from "@/utils/path-helpers";
import type { MybatisIndex, MybatisNavigationLocation } from "../types/mybatis.types";
import { workspaceRelativeMybatisPath } from "./mybatis-index-paths";

function matchesPath(indexPath: string, relativePath: string): boolean {
  return normalizePath(indexPath) === normalizePath(relativePath);
}

function toEditorLocation(
  root: string,
  relativePath: string,
  line: number,
  column: number,
  symbol: string,
): MybatisNavigationLocation {
  return {
    filePath: normalizePath(joinPath(root, relativePath)),
    line: Math.max(0, line - 1),
    column: Math.max(0, column - 1),
    symbol,
  };
}

function uniqueLocations(locations: MybatisNavigationLocation[]): MybatisNavigationLocation[] {
  const seen = new Set<string>();
  const unique: MybatisNavigationLocation[] = [];
  for (const location of locations) {
    const key = `${normalizePath(location.filePath)}:${location.line}:${location.column}`;
    if (seen.has(key)) continue;
    seen.add(key);
    unique.push(location);
  }
  return unique;
}

export function resolveMybatisDefinitions(
  index: MybatisIndex,
  root: string,
  filePath: string,
  caretLine: number,
): MybatisNavigationLocation[] {
  const relativePath = workspaceRelativeMybatisPath(filePath, root);
  if (!relativePath) return [];
  const oneBasedLine = caretLine + 1;

  const fromJava = index.statements
    .filter(
      (statement) =>
        matchesPath(statement.javaPath, relativePath) &&
        oneBasedLine >= statement.javaLine &&
        oneBasedLine <= statement.javaEndLine,
    )
    .map((statement) =>
      toEditorLocation(
        root,
        statement.xmlPath,
        statement.xmlLine,
        statement.xmlColumn,
        statement.statementId,
      ),
    );
  if (fromJava.length > 0) return uniqueLocations(fromJava);

  return uniqueLocations(
    index.statements
      .filter(
        (statement) =>
          matchesPath(statement.xmlPath, relativePath) && statement.xmlLine === oneBasedLine,
      )
      .map((statement) =>
        toEditorLocation(
          root,
          statement.javaPath,
          statement.javaLine,
          statement.javaColumn,
          statement.statementId,
        ),
      ),
  );
}
