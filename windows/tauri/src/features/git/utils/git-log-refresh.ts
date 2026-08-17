import { isGitChangeRelevant, type GitChange } from "../events/git-events";

const GIT_LOG_SCOPES = new Set(["history", "refs", "repository"]);

export function shouldRefreshGitLogForChange(change: GitChange, repoPath: string): boolean {
  if (!isGitChangeRelevant(change, repoPath)) return false;
  return !change.scopes?.length || change.scopes.some((scope) => GIT_LOG_SCOPES.has(scope));
}
