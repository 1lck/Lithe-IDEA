import type { GitReference } from "../types/git.types";

/** A current-branch/HEAD-only view already identifies its branch. */
export function shouldHighlightCurrentGitBranch(reference?: GitReference | null): boolean {
  return !reference || (!reference.isCurrent && reference.shortName !== "HEAD");
}
