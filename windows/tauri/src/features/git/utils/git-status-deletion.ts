export interface GitStatusDeleteFailure {
  path: string;
  error: unknown;
}

export interface GitStatusDeleteResult {
  failures: GitStatusDeleteFailure[];
  refreshError?: unknown;
}

export async function deleteGitStatusPaths(
  paths: readonly string[],
  deletePath: (path: string) => Promise<void>,
  refresh: () => Promise<void>,
): Promise<GitStatusDeleteResult> {
  const failures: GitStatusDeleteFailure[] = [];
  for (const path of paths) {
    try {
      await deletePath(path);
    } catch (error) {
      failures.push({ path, error });
    }
  }

  try {
    await refresh();
    return { failures };
  } catch (refreshError) {
    return { failures, refreshError };
  }
}
