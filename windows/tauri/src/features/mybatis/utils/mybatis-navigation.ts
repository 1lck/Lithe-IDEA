import { joinPath, normalizePath } from "@/utils/path-helpers";
import type { MybatisIndex, MybatisNavigationLocation } from "../types/mybatis.types";
import { workspaceRelativeMybatisPath } from "./mybatis-index-paths";

function matchesPath(indexPath: string, relativePath: string): boolean {
  return normalizePath(indexPath) === normalizePath(relativePath);
}

function containsSymbol(
  caretLine: number,
  caretColumn: number,
  symbolLine: number,
  symbolColumn: number,
  symbolEndColumn: number,
): boolean {
  const oneBasedLine = caretLine + 1;
  const oneBasedColumn = caretColumn + 1;
  return (
    oneBasedLine === symbolLine &&
    oneBasedColumn >= symbolColumn &&
    oneBasedColumn < symbolEndColumn
  );
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
  caretColumn: number,
): MybatisNavigationLocation[] {
  const relativePath = workspaceRelativeMybatisPath(filePath, root);
  if (!relativePath) return [];

  const fromJava = index.statements
    .filter(
      (statement) =>
        matchesPath(statement.javaPath, relativePath) &&
        containsSymbol(
          caretLine,
          caretColumn,
          statement.javaLine,
          statement.javaColumn,
          statement.javaEndColumn,
        ),
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
          matchesPath(statement.xmlPath, relativePath) &&
          containsSymbol(
            caretLine,
            caretColumn,
            statement.xmlLine,
            statement.xmlColumn,
            statement.xmlEndColumn,
          ),
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
