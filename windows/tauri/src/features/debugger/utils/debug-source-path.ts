import { normalizePath } from "@/utils/path-helpers";

/** Shared lexical identity for breakpoint mutation/query and editor projection.
 * Keep the existing drive-path case folding; do not rewrite stored source paths
 * or claim native filesystem/symlink identity for POSIX or remote sources.
 */
export function debugSourcePathKey(path: string): string {
  const normalized = normalizePath(path);
  return /^[A-Za-z]:\//.test(normalized) ? normalized.toLowerCase() : normalized;
}
