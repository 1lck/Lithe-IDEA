import { normalizeRepositoryPath } from "../api/git-repo-api";

/**
 * Eight hues chosen to stay legible on both light and dark surfaces, mirroring
 * the colored dot IntelliJ IDEA renders per repository in its Log view.
 */
export const GIT_REPOSITORY_COLOR_PALETTE: readonly string[] = [
  "#55d68b",
  "#65a9ff",
  "#d77eea",
  "#f3aa59",
  "#e76c72",
  "#56c7cf",
  "#b08cff",
  "#ffd166",
];

/**
 * Assigns each repository its palette color by its position in
 * `repositoryPaths`. Callers must pass the full repository list (before any
 * worktree filtering) so hiding a worktree never renumbers the repositories
 * that remain visible.
 */
export function buildGitRepositoryColorMap(
  repositoryPaths: readonly string[],
): Map<string, string> {
  const colors = new Map<string, string>();
  repositoryPaths.forEach((repositoryPath, index) => {
    const key = normalizeRepositoryPath(repositoryPath);
    if (colors.has(key)) return;
    colors.set(key, GIT_REPOSITORY_COLOR_PALETTE[index % GIT_REPOSITORY_COLOR_PALETTE.length]);
  });
  return colors;
}

/**
 * Resolves a single repository's color against the full repository list,
 * falling back to the first palette entry when the path is not part of the
 * workspace.
 */
export function resolveGitRepositoryColor(
  repositoryPath: string,
  repositoryPaths: readonly string[],
): string {
  const key = normalizeRepositoryPath(repositoryPath);
  const index = repositoryPaths.findIndex(
    (candidate) => normalizeRepositoryPath(candidate) === key,
  );
  return GIT_REPOSITORY_COLOR_PALETTE[
    (index < 0 ? 0 : index) % GIT_REPOSITORY_COLOR_PALETTE.length
  ];
}
