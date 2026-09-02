import { invoke as tauriInvoke } from "@/platform/tauri-core";
import type {
  GitCommit,
  GitCommitFile,
  GitHistoryPage,
  GitHistorySnapshot,
  GitOperationWarning,
  GitReferenceSnapshot,
} from "../types/git.types";
import { emitGitChanged } from "../events/git-events";
import { runGitRead } from "../runtime/git-read-coordinator";
import {
  isNotGitRepositoryError,
  resolveRepositoryPath,
  resolveRepositoryPathOrThrow,
} from "./git-repo-api";

interface GitWriteResult {
  output?: string;
  exitCode?: number;
  warnings?: GitOperationWarning[];
}

export type GitResetMode = "soft" | "mixed" | "hard";

const runHistoryMutation = async (
  repoPath: string,
  source: string,
  payload: Record<string, unknown>,
): Promise<GitOperationWarning[]> => {
  const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
  try {
    const result = await tauriInvoke<GitWriteResult>("git.write", {
      repoPath: resolvedRepoPath,
      ...payload,
    });
    if (typeof result?.exitCode === "number" && result.exitCode !== 0) {
      throw new Error(result.output?.trim() || "Git history operation failed");
    }
    return result?.warnings ?? [];
  } finally {
    // A rejected rewrite can leave conflicts or sequencer state behind.
    emitGitChanged({
      repoPath: resolvedRepoPath,
      scopes: ["working-tree", "history", "refs"],
      source,
    });
  }
};

export const commitChanges = async (repoPath: string, message: string): Promise<boolean> => {
  try {
    const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
    await tauriInvoke("git_commit", { repoPath: resolvedRepoPath, message });
    emitGitChanged({
      repoPath: resolvedRepoPath,
      scopes: ["working-tree", "history", "refs"],
      source: "commit",
    });
    return true;
  } catch (error) {
    console.error("Failed to commit changes:", error);
    return false;
  }
};

export const commitSelectedChanges = async (
  repoPath: string,
  message: string,
  filePaths: string[],
): Promise<GitOperationWarning[]> => {
  const uniqueFilePaths = [...new Set(filePaths)];
  if (uniqueFilePaths.length === 0) return [];

  return runHistoryMutation(repoPath, "commit", {
    operation: "commit",
    message,
    paths: uniqueFilePaths,
  });
};

export const getGitHistory = async (
  repoPath: string,
  limit = 50,
  reference?: string,
): Promise<GitHistorySnapshot | null> => {
  try {
    const resolvedRepoPath = await resolveRepositoryPath(repoPath);
    if (!resolvedRepoPath) {
      return null;
    }

    return await runGitRead(resolvedRepoPath, `log:${reference ?? "all"}:${limit}`, () =>
      tauriInvoke<GitHistorySnapshot>("git_log", {
        repoPath: resolvedRepoPath,
        limit,
        ...(reference ? { reference } : {}),
      }),
    );
  } catch (error) {
    if (!isNotGitRepositoryError(error)) {
      console.error("Failed to get git log:", error);
    }
    return null;
  }
};

export const getGitLog = async (repoPath: string, limit = 50): Promise<GitCommit[]> =>
  (await getGitHistory(repoPath, limit))?.commits ?? [];

export const cancelGitHistoryOperation = async (operationId: string): Promise<void> => {
  try {
    await tauriInvoke<boolean>("core_cancel", { operationId });
  } catch (error) {
    console.error("Failed to cancel git history operation:", error);
  }
};

export const getGitReferences = async (
  repoPath: string,
  operationId: string,
): Promise<GitReferenceSnapshot | null> => {
  try {
    const resolvedRepoPath = await resolveRepositoryPath(repoPath);
    if (!resolvedRepoPath) return null;
    return await runGitRead(resolvedRepoPath, `references:${operationId}`, () =>
      tauriInvoke<GitReferenceSnapshot>("git_references", {
        repoPath: resolvedRepoPath,
        operationId,
      }),
    );
  } catch (error) {
    if (!isNotGitRepositoryError(error)) console.error("Failed to get git references:", error);
    return null;
  }
};

export const getGitHistoryPage = async (
  repoPath: string,
  cursor: string | undefined,
  limit: number,
  operationId: string,
  reference?: string,
): Promise<GitHistoryPage | null> => {
  try {
    const resolvedRepoPath = await resolveRepositoryPath(repoPath);
    if (!resolvedRepoPath) return null;
    return await runGitRead(
      resolvedRepoPath,
      `log:${reference ?? "all"}:${cursor ?? "first"}:${limit}:${operationId}`,
      () =>
        tauriInvoke<GitHistoryPage>("git_history_page", {
          repoPath: resolvedRepoPath,
          limit,
          operationId,
          ...(cursor ? { cursor } : {}),
          ...(reference ? { reference } : {}),
        }),
    );
  } catch (error) {
    if (!isNotGitRepositoryError(error)) console.error("Failed to get git history page:", error);
    return null;
  }
};

export const closeGitHistoryCursor = async (
  repoPath: string,
  cursor: string,
): Promise<void> => {
  try {
    const resolvedRepoPath = await resolveRepositoryPath(repoPath);
    if (!resolvedRepoPath) return;
    await tauriInvoke<{ closed: boolean }>("git_history_cursor_close", {
      repoPath: resolvedRepoPath,
      cursor,
    });
  } catch (error) {
    if (!isNotGitRepositoryError(error)) {
      console.error("Failed to close git history cursor:", error);
    }
  }
};

export const getCommitFiles = async (
  repoPath: string,
  commitHash: string,
): Promise<GitCommitFile[] | null> => {
  try {
    const resolvedRepoPath = await resolveRepositoryPath(repoPath);
    if (!resolvedRepoPath) return null;

    const result = await runGitRead(resolvedRepoPath, `commit-files:${commitHash}`, () =>
      tauriInvoke<{ files: GitCommitFile[] }>("git.commitFiles", {
        repoPath: resolvedRepoPath,
        commit: commitHash,
      }),
    );
    return result.files ?? [];
  } catch (error) {
    if (!isNotGitRepositoryError(error)) {
      console.error("Failed to get files for commit:", error);
    }
    return null;
  }
};

export const editCommitMessage = (
  repoPath: string,
  revision: string,
  message: string,
): Promise<void> =>
  runHistoryMutation(repoPath, "edit-commit-message", {
    operation: "editCommitMessage",
    revision,
    message,
  }).then(() => undefined);

export const deleteCommit = (repoPath: string, revision: string): Promise<void> =>
  runHistoryMutation(repoPath, "delete-commit", {
    operation: "deleteCommit",
    revision,
  }).then(() => undefined);

export const squashCommits = (
  repoPath: string,
  revisions: string[],
  message: string,
): Promise<void> =>
  runHistoryMutation(repoPath, "squash-commits", {
    operation: "squashCommits",
    revisions,
    message,
  }).then(() => undefined);

export const resetToCommit = (
  repoPath: string,
  revision: string,
  mode: GitResetMode,
): Promise<void> =>
  runHistoryMutation(repoPath, "reset-to-commit", {
    operation: "reset",
    revision,
    mode: `--${mode}`,
  }).then(() => undefined);

export const cherryPickCommit = (repoPath: string, revision: string): Promise<void> =>
  runHistoryMutation(repoPath, "cherry-pick-commit", {
    operation: "cherryPick",
    revision,
  }).then(() => undefined);
