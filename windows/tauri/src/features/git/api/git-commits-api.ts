import type { GitExecutionSource } from "@/platform/git-execution-events";
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

function isCancelledGitHistoryRequest(error: unknown): boolean {
  const candidate =
    typeof error === "object" && error !== null
      ? (error as { code?: unknown; message?: unknown })
      : null;
  const code = typeof candidate?.code === "string" ? candidate.code.toLowerCase() : "";
  const message =
    error instanceof Error
      ? error.message
      : typeof error === "string"
        ? error
        : typeof candidate?.message === "string"
          ? candidate.message
          : "";

  return code === "cancelled" || message.trim().toLowerCase() === "operation was cancelled";
}

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
  source: GitExecutionSource = "unknown",
): Promise<GitHistorySnapshot | null> => {
  try {
    const resolvedRepoPath = await resolveRepositoryPath(repoPath);
    if (!resolvedRepoPath) {
      return null;
    }

    return await runGitRead(resolvedRepoPath, `log:${reference ?? "all"}:${limit}${source === "unknown" ? "" : `:${source}`}`, () => {
      const args = { repoPath: resolvedRepoPath, limit, ...(reference ? { reference } : {}) };
      return source === "unknown"
        ? tauriInvoke<GitHistorySnapshot>("git_log", args)
        : tauriInvoke<GitHistorySnapshot>("git_log", args, { gitExecutionSource: source });
    },
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
    if (!isNotGitRepositoryError(error) && !isCancelledGitHistoryRequest(error)) {
      console.error("Failed to get git references:", error);
    }
    return null;
  }
};

/**
 * Reads references for an already-discovered repository root, skipping
 * `git_discover_repo`. Reusing the known repository root avoids redundant Git
 * process launches when the workspace already resolved its repository roots.
 */
export const getGitReferencesAtRoot = async (
  repoPath: string,
  operationId: string,
): Promise<GitReferenceSnapshot | null> => {
  try {
    return await runGitRead(repoPath, `references:${operationId}`, () =>
      tauriInvoke<GitReferenceSnapshot>("git_references", {
        repoPath,
        operationId,
      }),
    );
  } catch (error) {
    if (isCancelledGitHistoryRequest(error)) return null;
    if (!isNotGitRepositoryError(error)) {
      console.error("Failed to get git references:", error);
    }
    throw error;
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
      // A cursor page consumes server-side state and cannot safely replay the same request.
      { retryOnInvalidation: false },
    );
  } catch (error) {
    if (!isNotGitRepositoryError(error) && !isCancelledGitHistoryRequest(error)) {
      console.error("Failed to get git history page:", error);
    }
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

interface GitCommitLookupResult {
  commit?: { hash?: string; subject?: string };
  body?: string;
}

/** The checked-out commit an amend would rewrite, as the message editor shows it. */
export interface HeadCommitMessage {
  message: string;
  /** Full object ID of the commit the message was read from. */
  hash: string;
}

/**
 * Reads the full message of the checked-out HEAD for amending, together with the HEAD it
 * came from so Core can refuse the amend once HEAD has moved. History pages list every
 * reference and carry only subjects, so they cannot stand in for it.
 * Returns null when HEAD has no commit yet or cannot be read.
 */
export const getHeadCommitMessage = async (repoPath: string): Promise<HeadCommitMessage | null> => {
  try {
    const resolvedRepoPath = await resolveRepositoryPath(repoPath);
    if (!resolvedRepoPath) return null;
    const result = await runGitRead(resolvedRepoPath, "head-commit-message", () =>
      tauriInvoke<GitCommitLookupResult>("git.commit", {
        repoPath: resolvedRepoPath,
        commit: "HEAD",
      }),
    );
    const subject = result?.commit?.subject ?? "";
    if (!result?.commit?.hash) return null;
    const body = typeof result.body === "string" ? result.body : "";
    return { message: body ? `${subject}\n\n${body}` : subject, hash: result.commit.hash };
  } catch (error) {
    if (!isNotGitRepositoryError(error)) {
      console.error("Failed to read HEAD commit message:", error);
    }
    return null;
  }
};

/**
 * History pages carry only the subject so paging stays compact; the message
 * body is read on demand when one commit is inspected, copied, or diffed.
 * A commit object is immutable, so a body never goes stale for its hash.
 */
const COMMIT_DESCRIPTION_CACHE_LIMIT = 200;
const commitDescriptionCache = new Map<string, string>();

const rememberCommitDescription = (key: string, description: string) => {
  commitDescriptionCache.delete(key);
  commitDescriptionCache.set(key, description);
  if (commitDescriptionCache.size > COMMIT_DESCRIPTION_CACHE_LIMIT) {
    const oldest = commitDescriptionCache.keys().next().value;
    if (oldest !== undefined) commitDescriptionCache.delete(oldest);
  }
};

/** Returns the commit message body after the subject, or null when it cannot be read. */
export const getCommitDescription = async (
  repoPath: string,
  commitHash: string,
): Promise<string | null> => {
  try {
    const resolvedRepoPath = await resolveRepositoryPath(repoPath);
    if (!resolvedRepoPath) return null;
    const cacheKey = JSON.stringify([resolvedRepoPath, commitHash]);
    const cached = commitDescriptionCache.get(cacheKey);
    if (cached !== undefined) {
      rememberCommitDescription(cacheKey, cached);
      return cached;
    }

    const result = await runGitRead(resolvedRepoPath, `commit-details:${commitHash}`, () =>
      tauriInvoke<GitCommitLookupResult>("git.commit", {
        repoPath: resolvedRepoPath,
        commit: commitHash,
      }),
    );
    const description = typeof result?.body === "string" ? result.body : "";
    rememberCommitDescription(cacheKey, description);
    return description;
  } catch (error) {
    if (!isNotGitRepositoryError(error)) {
      console.error("Failed to get commit details:", error);
    }
    return null;
  }
};

/** Fills `description` from the full message; keeps the subject-only commit on failure. */
export const withCommitDescription = async (
  repoPath: string,
  commit: GitCommit,
): Promise<GitCommit> => {
  if (commit.description !== undefined) return commit;
  const description = await getCommitDescription(repoPath, commit.hash);
  return description === null ? commit : { ...commit, description };
};

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

export const revertCommit = (repoPath: string, revision: string): Promise<void> =>
  runHistoryMutation(repoPath, "revert-commit", {
    operation: "revert",
    revision,
  }).then(() => undefined);
