import { normalizeRepositoryPath } from "../api/git-repo-api";

/**
 * A directory is a Git repository root only when its normalized path matches a
 * discovered repository path exactly. The workspace root is covered by the same
 * comparison because discovery reports it as a repository when it is one.
 */
export function isGitRepositoryRoot(
  candidatePath: string | null | undefined,
  availableRepoPaths: readonly string[],
): boolean {
  if (!candidatePath) return false;

  const normalizedCandidate = normalizeRepositoryPath(candidatePath);
  if (!normalizedCandidate) return false;

  return availableRepoPaths.some(
    (repoPath) => normalizeRepositoryPath(repoPath) === normalizedCandidate,
  );
}
