import { isGitChangeRelevant, type GitChange } from "../events/git-events";
import type { GitReference } from "../types/git.types";

const GIT_LOG_SCOPES = new Set(["history", "refs", "repository"]);

export function shouldRefreshGitLogForChange(change: GitChange, repoPath: string): boolean {
  if (!isGitChangeRelevant(change, repoPath)) return false;
  return !change.scopes?.length || change.scopes.some((scope) => GIT_LOG_SCOPES.has(scope));
}

export function selectedReferenceAfterRemoval(
  selectedReference: GitReference | null,
  removedFullName: string,
): GitReference | null {
  return selectedReference?.fullName === removedFullName ? null : selectedReference;
}

export function reconcileGitLogReference(
  reference: GitReference | null,
  refreshedReferences: GitReference[] | null,
): { reference: GitReference | null; isMissing: boolean } {
  if (!reference || refreshedReferences === null) {
    return { reference, isMissing: false };
  }

  const refreshedReference = refreshedReferences.find(
    (candidate) => candidate.fullName === reference.fullName,
  );
  return refreshedReference
    ? { reference: refreshedReference, isMissing: false }
    : { reference: null, isMissing: true };
}
