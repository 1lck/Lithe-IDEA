import { pathStartsWithRoot } from "@/utils/path-helpers";
import { normalizeRepositoryPath } from "../api/git-repo-api";

/**
 * A linked worktree or submodule repository always lives inside its primary
 * repository's directory tree, so a repository with a strict ancestor in the
 * same workspace is treated as a linked worktree repository.
 */
export function isLinkedWorktreeRepository(
  repositoryPath: string,
  repositoryPaths: readonly string[],
): boolean {
  const normalizedRepositoryPath = normalizeRepositoryPath(repositoryPath);
  return repositoryPaths.some((candidate) => {
    const normalizedCandidate = normalizeRepositoryPath(candidate);
    return (
      normalizedCandidate !== normalizedRepositoryPath &&
      pathStartsWithRoot(normalizedRepositoryPath, normalizedCandidate)
    );
  });
}

/**
 * Repository paths the reference tree groups by. Hiding worktree repositories
 * drops nested ones while always retaining the active repository, so selecting
 * a worktree never removes it from the grouping.
 */
export function resolveVisibleRepositoryPaths(
  repositoryPaths: readonly string[],
  activeRepositoryPath: string,
  showWorktreeRepositories: boolean,
): string[] {
  if (repositoryPaths.length <= 1 || showWorktreeRepositories) return [...repositoryPaths];
  const activeRepositoryKey = normalizeRepositoryPath(activeRepositoryPath);
  return repositoryPaths.filter(
    (repositoryPath) =>
      normalizeRepositoryPath(repositoryPath) === activeRepositoryKey ||
      !isLinkedWorktreeRepository(repositoryPath, repositoryPaths),
  );
}
