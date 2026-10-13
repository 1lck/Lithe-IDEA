import { normalizePath, stripTrailingPathSeparators } from "@/utils/path-helpers";

const SCHEME_PREFIX = /^[A-Za-z][A-Za-z0-9+.-]*:\/\//;
const WINDOWS_DRIVE_ABSOLUTE = /^[A-Za-z]:\//;
const WINDOWS_UNC_ABSOLUTE = /^\/\/[^/]/;

export function isSupportedSpringRoot(root: string | null | undefined): root is string {
  if (!root || SCHEME_PREFIX.test(root)) return false;
  const normalized = normalizePath(root);
  return WINDOWS_DRIVE_ABSOLUTE.test(normalized) || WINDOWS_UNC_ABSOLUTE.test(normalized);
}

export function normalizeSpringRootIdentity(root: string | null | undefined): string | null {
  if (!isSupportedSpringRoot(root)) return null;
  const normalized = stripTrailingPathSeparators(normalizePath(root));
  return WINDOWS_DRIVE_ABSOLUTE.test(normalized) ? normalized.toLowerCase() : normalized;
}

export function isSameSpringRoot(
  left: string | null | undefined,
  right: string | null | undefined,
): boolean {
  const leftIdentity = normalizeSpringRootIdentity(left);
  const rightIdentity = normalizeSpringRootIdentity(right);
  return leftIdentity !== null && leftIdentity === rightIdentity;
}
