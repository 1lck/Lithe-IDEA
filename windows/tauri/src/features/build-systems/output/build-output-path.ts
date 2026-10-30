import { joinPath, normalizePath, pathStartsWithRoot } from "@/utils/path-helpers";

/**
 * Guard for the source locations Core-decoded diagnostics and test cases
 * report. Core already relativizes reported paths against the workspace, but
 * decoded output is still untrusted input by the time it reaches the view, so
 * the last step before opening an editor re-checks it: only a plain
 * workspace-relative path with `/` separators may become a clickable target,
 * and the joined result must stay inside the workspace root. Virtual schemes
 * (`remote://`, `wsl://`, `file://`), absolute drives and UNC roots, and
 * traversal segments are refused; a refused location renders as plain text.
 */

const INVALID_SEGMENT = /[<>:"|?*\\]/;
const RESERVED_SEGMENT = /^(con|prn|aux|nul|com[1-9¹²³]|lpt[1-9¹²³])(?:\.|$)/i;

function isFileSegment(segment: string): boolean {
  for (const character of segment) {
    if (character.charCodeAt(0) < 32) return false;
  }
  return (
    !!segment &&
    segment !== "." &&
    segment !== ".." &&
    !INVALID_SEGMENT.test(segment) &&
    !/[. ]$/.test(segment) &&
    !RESERVED_SEGMENT.test(segment)
  );
}

/** Editor locations must be finite, integral, one-based coordinates. */
export function isSourceCoordinate(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 1;
}

/** Whether `reportedPath` is a plain workspace-relative path. */
export function isWorkspaceRelativePath(reportedPath: string): boolean {
  if (!reportedPath || reportedPath.length > 512) return false;
  if (reportedPath.includes("://")) return false;
  if (reportedPath.startsWith("/") || reportedPath.startsWith("\\")) return false;
  if (/^[A-Za-z]:/.test(reportedPath)) return false;
  const segments = reportedPath.split("/");
  for (const segment of segments) {
    if (!isFileSegment(segment)) return false;
  }
  return true;
}

/**
 * Absolute path of `reportedPath` under `workspaceRoot`, or null when the
 * path is not a legal workspace-relative location. The containment re-check
 * mirrors the macOS `BuildOutputSourcePath` guard so both platforms refuse
 * the same class of link at the view boundary.
 */
export function resolveWorkspaceSourcePath(
  workspaceRoot: string,
  reportedPath: string,
): string | null {
  if (!workspaceRoot || !isWorkspaceRelativePath(reportedPath)) return null;
  const root = normalizePath(workspaceRoot);
  // joinPath is lexical, so validate the root as well as the reported path.
  // Reject virtual roots, device namespaces, drive-relative paths and escapes.
  const cleanRoot = root.replace(/\/+$/, "");
  const segments = /^[A-Za-z]:\//.test(root)
    ? root.length === 3
      ? []
      : cleanRoot.slice(3).split("/")
    : cleanRoot.startsWith("//")
      ? cleanRoot.slice(2).split("/")
      : null;
  if (
    !segments ||
    (root.startsWith("//") && segments.length < 2) ||
    segments.some((segment) => !isFileSegment(segment)) ||
    root.includes("://")
  )
    return null;
  const candidate = joinPath(root, reportedPath);
  if (!pathStartsWithRoot(candidate, root)) return null;
  return candidate;
}
