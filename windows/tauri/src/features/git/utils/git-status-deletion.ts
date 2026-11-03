export interface GitStatusDeleteFailure {
  path: string;
  error: unknown;
}

export interface GitStatusDeleteResult {
  failures: GitStatusDeleteFailure[];
  refreshError?: unknown;
  reconciliationError?: unknown;
}

export async function deleteGitStatusPaths(
  paths: readonly string[],
  deletePath: (path: string) => Promise<void>,
  refresh: () => Promise<void>,
  reconcile: () => Promise<void> = async () => {},
): Promise<GitStatusDeleteResult> {
  const failures: GitStatusDeleteFailure[] = [];
  for (const path of paths) {
    try {
      await deletePath(path);
    } catch (error) {
      failures.push({ path, error });
    }
  }

  let reconciliationError: unknown;
  try {
    await reconcile();
  } catch (error) {
    reconciliationError = error;
  }
  try {
    await refresh();
    return reconciliationError ? { failures, reconciliationError } : { failures };
  } catch (refreshError) {
    return reconciliationError
      ? { failures, refreshError, reconciliationError }
      : { failures, refreshError };
  }
}
