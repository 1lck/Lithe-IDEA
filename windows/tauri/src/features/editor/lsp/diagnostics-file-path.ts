import { normalizePath } from "@/utils/path-helpers";

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

export function resolvePublishedDiagnosticsFilePath(
  publishedFilePath: string,
  sourceBufferPaths: Iterable<string>,
  openDocumentPaths: Iterable<string>,
): string | null {
  const publishedPathKey = diagnosticPathKey(publishedFilePath);
  return (
    findEquivalentPath(publishedPathKey, sourceBufferPaths) ??
    findEquivalentPath(publishedPathKey, openDocumentPaths)
  );
}
