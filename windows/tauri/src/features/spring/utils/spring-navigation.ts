import { joinPath, normalizePath } from "@/utils/path-helpers";
import type {
  SpringIndex,
  SpringNavigationLocation,
} from "../types/spring.types";
import { workspaceRelativeSpringPath } from "./spring-index-paths";

function matchesLine(indexLine: number, caretZeroBased: number, tolerance = 0): boolean {
  return Math.abs(indexLine - (caretZeroBased + 1)) <= tolerance;
}

function matchesPath(indexPath: string, relativePath: string): boolean {
  return normalizePath(indexPath) === normalizePath(relativePath);
}

function toEditorLocation(
  root: string,
  relativePath: string,
  line?: number | null,
  column?: number | null,
  symbol = "",
): SpringNavigationLocation | null {
  if (!relativePath) return null;
  return {
    filePath: normalizePath(joinPath(root, relativePath)),
    line: Math.max(0, (line ?? 1) - 1),
    column: Math.max(0, (column ?? 1) - 1),
    symbol,
  };
}

function uniqueLocations(locations: SpringNavigationLocation[]): SpringNavigationLocation[] {
  const seen = new Set<string>();
  const unique: SpringNavigationLocation[] = [];
  for (const location of locations) {
    const key = `${normalizePath(location.filePath)}:${location.line}:${location.column}`;
    if (seen.has(key)) continue;
    seen.add(key);
    unique.push(location);
  }
  return unique;
}

export function resolveSpringDefinitions(
  index: SpringIndex,
  root: string,
  filePath: string,
  caretLine: number,
): SpringNavigationLocation[] {
  const relativePath = workspaceRelativeSpringPath(filePath, root);
  if (!relativePath) return [];

  const value = index.values.find(
    (candidate) => matchesPath(candidate.path, relativePath) && matchesLine(candidate.line, caretLine),
  );
  if (value) {
    const locations: SpringNavigationLocation[] = [];
    if (value.targetPath) {
      const target = toEditorLocation(
        root,
        value.targetPath,
        value.targetLine,
        value.targetColumn,
        value.key,
      );
      if (target) locations.push(target);
    }
    for (const reference of index.propertyReferences.filter((candidate) => candidate.key === value.key)) {
      const location = toEditorLocation(root, reference.path, reference.line, reference.column, value.key);
      if (location) locations.push(location);
    }
    if (locations.length > 0) return uniqueLocations(locations);
  }

  const reference = index.propertyReferences.find(
    (candidate) => matchesPath(candidate.path, relativePath) && matchesLine(candidate.line, caretLine),
  );
  if (reference) {
    return uniqueLocations(
      index.values
        .filter((candidate) => candidate.key === reference.key)
        .flatMap((candidate) => {
          const location = toEditorLocation(
            root,
            candidate.path,
            candidate.line,
            candidate.column,
            candidate.key,
          );
          return location ? [location] : [];
        }),
    );
  }

  const injection = index.injections.find(
    (candidate) =>
      matchesPath(candidate.path, relativePath) && matchesLine(candidate.line, caretLine, 1),
  );
  if (injection) {
    return uniqueLocations(
      injection.beanIds.flatMap((beanId) => {
        const bean = index.beans.find((candidate) => candidate.id === beanId);
        if (!bean) return [];
        const location = toEditorLocation(root, bean.path, bean.line, bean.column, bean.name);
        return location ? [location] : [];
      }),
    );
  }

  const matchingProperties = index.properties.filter(
    (property) =>
      property.sourcePath &&
      matchesPath(property.sourcePath, relativePath) &&
      property.sourceLine != null &&
      matchesLine(property.sourceLine, caretLine, 1),
  );
  return uniqueLocations(
    matchingProperties.flatMap((property) =>
      index.values
        .filter((candidate) => candidate.key === property.name)
        .flatMap((candidate) => {
          const location = toEditorLocation(
            root,
            candidate.path,
            candidate.line,
            candidate.column,
            candidate.key,
          );
          return location ? [location] : [];
        }),
    ),
  );
}

export function resolveSpringReferences(
  index: SpringIndex,
  root: string,
  filePath: string,
  caretLine: number,
): SpringNavigationLocation[] {
  const definitions = resolveSpringDefinitions(index, root, filePath, caretLine);
  if (definitions.length === 0) return [];

  const relativePath = workspaceRelativeSpringPath(filePath, root);
  const value = index.values.find(
    (candidate) => matchesPath(candidate.path, relativePath) && matchesLine(candidate.line, caretLine),
  );
  const reference = index.propertyReferences.find(
    (candidate) => matchesPath(candidate.path, relativePath) && matchesLine(candidate.line, caretLine),
  );
  const key = value?.key ?? reference?.key;
  if (!key) return definitions;

  const origin = toEditorLocation(root, relativePath, caretLine + 1, 1, key);
  return uniqueLocations([
    ...(origin ? [origin] : []),
    ...definitions,
    ...index.values
      .filter((candidate) => candidate.key === key)
      .flatMap((candidate) => {
        const location = toEditorLocation(
          root,
          candidate.path,
          candidate.line,
          candidate.column,
          candidate.key,
        );
        return location ? [location] : [];
      }),
    ...index.propertyReferences
      .filter((candidate) => candidate.key === key)
      .flatMap((candidate) => {
        const location = toEditorLocation(
          root,
          candidate.path,
          candidate.line,
          candidate.column,
          candidate.key,
        );
        return location ? [location] : [];
      }),
  ]);
}
