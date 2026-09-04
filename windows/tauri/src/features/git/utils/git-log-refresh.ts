import { isGitChangeRelevant, type GitChange } from "../events/git-events";
import type { GitHistorySnapshot, GitReference } from "../types/git.types";

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

export async function loadGitHistoryWithReferenceFallback(
  loadHistory: (reference?: string) => Promise<GitHistorySnapshot | null>,
  reference: GitReference | null,
): Promise<{ history: GitHistorySnapshot | null; reference: GitReference | null }> {
  const history = await loadHistory(reference?.fullName);
  if (history || !reference) return { history, reference };
  return { history: await loadHistory(), reference: null };
}
