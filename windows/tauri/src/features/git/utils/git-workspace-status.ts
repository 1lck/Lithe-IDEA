import type { GitFile, GitStatus } from "../types/git.types";

export type GitRepositoryStatuses = Record<string, GitStatus | null>;

/** Build the Commit view from repository-owned snapshots without changing file identity. */
export function projectWorkspaceGitStatus(
  repositoryStatuses: GitRepositoryStatuses,
  repoPaths: readonly string[],
  activeRepoPath: string | null,
): GitStatus | null {
  const activeStatus = activeRepoPath ? repositoryStatuses[activeRepoPath] : null;
  if (!activeStatus) return null;
  const statuses = repoPaths.flatMap((repoPath) => {
    const status = repositoryStatuses[repoPath];
    return status ? [{ repoPath, status }] : [];
  });
  if (statuses.length <= 1) return activeStatus;
  const label = (path: string) =>
    path.replace(/\\/g, "/").replace(/\/+$/, "").split("/").pop() || "repository";
  const labels = statuses.map(({ repoPath }) => label(repoPath));
  const files = statuses.flatMap(({ repoPath, status }, index) => {
    const repoLabel = labels[index]!;
    const prefix =
      labels.indexOf(repoLabel) !== labels.lastIndexOf(repoLabel)
        ? repoPath.replace(/\\/g, "/")
        : repoLabel;
    return status.files.map(
      (file): GitFile => ({
        ...file,
        path: `${prefix}/${file.path}`,
        originalPath: file.originalPath ? `${prefix}/${file.originalPath}` : undefined,
        repositoryPath: repoPath,
        repositoryRelativePath: file.path,
        repositoryOriginalRelativePath: file.originalPath,
      }),
    );
  });
  return { ...activeStatus, files };
}
