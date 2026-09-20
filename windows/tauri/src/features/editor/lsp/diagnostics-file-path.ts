import { normalizePath, pathStartsWithRoot } from "@/utils/path-helpers";

function diagnosticPathKey(filePath: string): string {
  const normalizedPath = normalizePath(filePath);
  return /^(?:[A-Za-z]:\/|\/\/)/.test(normalizedPath)
    ? normalizedPath.toLowerCase()
    : normalizedPath;
}

function findEquivalentPath(
  publishedPathKey: string,
  candidatePaths: Iterable<string>,
): string | null {
  for (const candidatePath of candidatePaths) {
    if (diagnosticPathKey(candidatePath) === publishedPathKey) return candidatePath;
  }
  return null;
}

/**
 * Resolves the path a published diagnostic should be stored under.
 *
 * A path already known to the product wins, so diagnostics for an open file
 * keep that file's exact spelling and stay mergeable with its other owners.
 * Otherwise the diagnostic is kept under its own normalized path when it falls
 * inside one of the workspace roots: a language server reports errors for
 * files the user never opened, and a launch blocked by a compilation error is
 * only actionable when those errors are visible. Anything outside the
 * workspace — JDK sources, dependency jars, decompiled class files — is
 * dropped.
 *
 * Passing no workspace roots keeps the open-document-only behavior.
 */
export function resolvePublishedDiagnosticsFilePath(
  publishedFilePath: string,
  sourceBufferPaths: Iterable<string>,
  openDocumentPaths: Iterable<string>,
  workspaceRoots: Iterable<string> = [],
): string | null {
  const publishedPathKey = diagnosticPathKey(publishedFilePath);
  const knownPath =
    findEquivalentPath(publishedPathKey, sourceBufferPaths) ??
    findEquivalentPath(publishedPathKey, openDocumentPaths);
  if (knownPath) return knownPath;

  for (const workspaceRoot of workspaceRoots) {
    if (workspaceRoot && pathStartsWithRoot(publishedFilePath, workspaceRoot)) {
      return normalizePath(publishedFilePath);
    }
  }
  return null;
}
