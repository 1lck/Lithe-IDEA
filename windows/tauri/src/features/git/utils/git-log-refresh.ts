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

export function selectedReferenceAfterRename(
  selectedReference: GitReference | null,
  renamedFromFullName: string,
  renamedReference: GitReference,
): GitReference | null {
  return selectedReference?.fullName === renamedFromFullName ? renamedReference : selectedReference;
}

/**
 * True for a remote symbolic reference such as `origin/HEAD`, which Git keeps
 * as a pointer to the remote's default branch rather than a normal branch.
 */
export function isRemoteSymbolicReference(reference: GitReference): boolean {
  return reference.kind === "remote" && reference.fullName.endsWith("/HEAD");
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
  if (refreshedReference) {
    return { reference: refreshedReference, isMissing: false };
  }

  // A remote symbolic `HEAD` is a real reference, but a snapshot may list only
  // the remote's branches rather than `origin/HEAD` itself. Treat it as present
  // when its published symbolic target or its remote namespace still exists, so
  // selecting it never trips the missing-reference fallback reload. The caller
  // keeps the clicked reference selected.
  if (isRemoteSymbolicReference(reference)) {
    const symbolicTarget =
      (reference.upstreamShortName
        ? refreshedReferences.find(
            (candidate) => candidate.shortName === reference.upstreamShortName,
          )
        : undefined) ??
      refreshedReferences.find(
        (candidate) =>
          candidate.fullName !== reference.fullName &&
          candidate.fullName.startsWith(reference.fullName.slice(0, -"HEAD".length)),
      );
    if (symbolicTarget) return { reference, isMissing: false };
  }

  return { reference: null, isMissing: true };
}
