import { getPathIdentity, pathStartsWithRoot } from "@/utils/path-helpers";

/** The closest explicitly opened root owns a path, including nested added roots. */
export function closestWorkspaceRoot(path: string, roots: readonly string[]): string | undefined {
  return roots
    .filter((root) => pathStartsWithRoot(path, root))
    .sort((a, b) => getPathIdentity(b).length - getPathIdentity(a).length)[0];
}
