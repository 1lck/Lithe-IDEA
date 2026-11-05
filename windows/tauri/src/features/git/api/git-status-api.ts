import { frontendTrace } from "@/utils/frontend-trace";
import type { GitExecutionSource } from "@/platform/git-execution-events";
import { invoke as tauriInvoke } from "@/platform/tauri-core";
import { emitGitChanged } from "../events/git-events";
import { createRepositoryWriteQueue } from "../services/git-operation-coordinator";
import { registerGitCacheInvalidator } from "../runtime/git-cache-registry";
import { initializeGitRepository } from "./git-setup-api";
import type { GitFile, GitHunk, GitStatus } from "../types/git.types";
import {
  projectWorkspaceGitStatus,
  type GitRepositoryStatuses,
} from "../utils/git-workspace-status";
import { listExpandedUntrackedDirectories } from "../services/git-untracked-directory-expansions";
import {
  isNotGitRepositoryError,
  resolveRepositoryPath,
  resolveRepositoryPathOrThrow,
} from "./git-repo-api";

const enqueueStagingWrite = createRepositoryWriteQueue();

const inFlightGitStatusRequests = new Map<string, Promise<GitStatus | null>>();
const gitStatusGenerations = new Map<string, number>();

registerGitCacheInvalidator(({ repoPath }) => {
  if (!repoPath) {
    for (const [cachedRepoPath, generation] of gitStatusGenerations) {
      gitStatusGenerations.set(cachedRepoPath, generation + 1);
    }
    inFlightGitStatusRequests.clear();
    return;
  }

  gitStatusGenerations.set(repoPath, (gitStatusGenerations.get(repoPath) ?? 0) + 1);
  for (const key of inFlightGitStatusRequests.keys()) {
    if (key.startsWith(`${repoPath}\0`)) inFlightGitStatusRequests.delete(key);
  }
});

export const getGitStatus = async (repoPath: string): Promise<GitStatus | null> => {
  try {
    return await queryGitStatus(repoPath);
  } catch (error) {
    if (!isNotGitRepositoryError(error)) console.error("Failed to get git status:", error);
    return null;
  }
};

// Keep failures distinct from a missing repository for workspace refreshes.
// Optional status consumers retain the nullable getGitStatus API.
const queryGitStatus = async (
  repoPath: string,
  source: GitExecutionSource = "unknown",
  repositoryRoots: readonly string[] = [],
  summarizeUntrackedDirectories = false,
): Promise<GitStatus | null> => {
  const resolvedRepoPath = await resolveRepositoryPath(repoPath);

  if (!resolvedRepoPath) {
    return null;
  }

  const requestKey = `${resolvedRepoPath}\0${source}\0${JSON.stringify(repositoryRoots)}\0${summarizeUntrackedDirectories}`;
  const existingRequest = inFlightGitStatusRequests.get(requestKey);
  if (existingRequest) {
    return existingRequest;
  }

  const generation = gitStatusGenerations.get(resolvedRepoPath) ?? 0;
  if (!gitStatusGenerations.has(resolvedRepoPath)) {
    gitStatusGenerations.set(resolvedRepoPath, generation);
  }
  const payload = {
    repoPath: resolvedRepoPath,
    includeIndexOnlyChanges: true,
    repositoryRoots,
    ...(summarizeUntrackedDirectories ? { summarizeUntrackedDirectories } : {}),
  };
  const request = (
    source === "unknown"
      ? tauriInvoke<GitStatus>("git_status", payload)
      : tauriInvoke<GitStatus>("git_status", payload, { gitExecutionSource: source })
  )
    .then((status) => {
      if (generation !== (gitStatusGenerations.get(resolvedRepoPath) ?? 0)) {
        return queryGitStatus(
          resolvedRepoPath,
          source,
          repositoryRoots,
          summarizeUntrackedDirectories,
        );
      }
      return status;
    })
    .finally(() => {
      if (inFlightGitStatusRequests.get(requestKey) === request) {
        inFlightGitStatusRequests.delete(requestKey);
      }
    });

  inFlightGitStatusRequests.set(requestKey, request);
  return request;
};

function normalizeStatusRepoPaths(repoPaths: readonly string[]): string[] {
  return [...new Set(repoPaths.map((repoPath) => repoPath.trim()).filter(Boolean))];
}

// Bootstrap must await every repository without changing the root-relative
// snapshot consumed by the file tree and the workspace footer.
export async function getWorkspaceRootGitStatus(
  workspacePath: string,
  repoPaths: readonly string[],
): Promise<GitStatus | null> {
  const [rootStatus] = await Promise.all([
    queryGitStatus(workspacePath),
    ...normalizeStatusRepoPaths(repoPaths).map(async (repoPath) => {
      const status = await queryGitStatus(repoPath);
      if (!status) throw new Error("Git status query returned no snapshot");
    }),
  ]);
  return rootStatus;
}

/**
 * Read raw repository snapshots; optional workspace roots may have no Git repository.
 *
 * These snapshots feed `repositoryStatuses`, so a large wholly untracked
 * directory arrives as one summary and expanded summaries list their contents
 * here (#1385). One-off readers such as Shelve keep the file-level `getGitStatus`.
 */
export async function getRepositoryGitStatuses(
  repoPaths: readonly string[],
  source: GitExecutionSource = "unknown",
  requiredRepoPaths: readonly string[] = repoPaths,
): Promise<GitRepositoryStatuses> {
  const normalizedRepoPaths = normalizeStatusRepoPaths(repoPaths);
  const required = new Set(requiredRepoPaths);
  const entries = await Promise.all(
    normalizedRepoPaths.map(async (repoPath) => {
      const status = await queryGitStatus(repoPath, source, requiredRepoPaths, true);
      if (!status && required.has(repoPath))
        throw new Error("Git status query returned no snapshot");
      return [
        repoPath,
        status && (await withExpandedUntrackedDirectories(repoPath, status, requiredRepoPaths)),
      ] as const;
    }),
  );
  return Object.fromEntries(entries);
}

export interface GitWorkspaceStatusRefresh {
  statuses: GitRepositoryStatuses;
  confirmedRoots: string[];
  failedRoots: string[];
}

/** Preserve only confirmed old snapshots when an individual repository read fails. */
export async function getWorkspaceStatusRefresh(
  repoPaths: readonly string[],
  source: GitExecutionSource,
  requiredRepoPaths: readonly string[],
  previous: GitRepositoryStatuses,
): Promise<GitWorkspaceStatusRefresh> {
  const roots = normalizeStatusRepoPaths(repoPaths);
  const required = new Set(requiredRepoPaths);
  const reads = await Promise.all(roots.map(async (root) => {
    try {
      const status = await queryGitStatus(root, source, requiredRepoPaths, true);
      if (!status && required.has(root)) return { root, success: false as const, status: null };
      return { root, success: true as const,
        status: status && await withExpandedUntrackedDirectories(root, status, requiredRepoPaths) };
    } catch (error) {
      console.error("Failed to refresh repository Git status:", root, error);
      return { root, success: false as const, status: null };
    }
  }));
  const plan = await tauriInvoke<{
    entries: Array<{ root: string; source: "current" | "previous" | "missing" }>;
    confirmedRoots: string[];
    failedRoots: string[];
  }>("git.workspaceStatusMerge", {
    roots,
    previousRoots: Object.keys(previous).filter((root) => previous[root] != null),
    outcomes: reads.map(({ root, success }) => ({ root, success })),
  });
  if (!plan || plan.entries.length !== roots.length) throw new Error("Invalid workspace Git status plan");
  const statuses: GitRepositoryStatuses = {};
  for (let index = 0; index < roots.length; index += 1) {
    const root = roots[index]!;
    const entry = plan.entries[index];
    const read = reads[index]!;
    if (!entry || entry.root !== root) throw new Error("Invalid workspace Git status plan");
    if (entry.source === "current" && read.success) statuses[root] = read.status;
    else if (entry.source === "previous" && !read.success && previous[root]) statuses[root] = previous[root]!;
    else if (entry.source === "missing" && !read.success && !previous[root]) statuses[root] = null;
    else throw new Error("Invalid workspace Git status plan");
  }
  return { statuses, confirmedRoots: plan.confirmedRoots, failedRoots: plan.failedRoots };
}

async function withExpandedUntrackedDirectories(
  repoPath: string,
  status: GitStatus,
  repositoryRoots: readonly string[],
): Promise<GitStatus> {
  const files = await listExpandedUntrackedDirectories(repoPath, status.files, (directory) =>
    listUntrackedDirectory(repoPath, directory, repositoryRoots),
  );
  return files.length === status.files.length ? status : { ...status, files };
}

/**
 * Lists the immediate files and subdirectory summaries of one summarized
 * untracked directory, or null when Git could not list it.
 */
export async function listUntrackedDirectory(
  repoPath: string,
  directory: string,
  repositoryRoots: readonly string[] = [],
): Promise<GitFile[] | null> {
  try {
    const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
    const listing = await tauriInvoke<{ files: GitFile[] }>("git.untrackedDirectory", {
      repoPath: resolvedRepoPath,
      directory,
      repositoryRoots,
    });
    return listing.files;
  } catch (error) {
    console.error("Failed to list untracked directory:", error);
    return null;
  }
}

export const getWorkspaceGitStatus = async (
  repoPaths: readonly string[],
  activeRepoPath?: string,
  source: GitExecutionSource = "unknown",
): Promise<GitStatus | null> => {
  const normalizedRepoPaths = normalizeStatusRepoPaths(repoPaths);
  if (normalizedRepoPaths.length === 0) return null;
  const statuses = await getRepositoryGitStatuses(normalizedRepoPaths, source);
  return projectWorkspaceGitStatus(
    statuses,
    normalizedRepoPaths,
    activeRepoPath && statuses[activeRepoPath] ? activeRepoPath : normalizedRepoPaths[0]!,
  );
};

export const stageFile = async (repoPath: string, filePath: string): Promise<boolean> => {
  try {
    const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
    await tauriInvoke("git_add", { repoPath: resolvedRepoPath, filePath });
    emitGitChanged({
      repoPath: resolvedRepoPath,
      filePath,
      scopes: ["working-tree"],
      source: "stage-file",
    });
    return true;
  } catch (error) {
    console.error("Failed to stage file:", error);
    return false;
  }
};

export const unstageFile = async (repoPath: string, filePath: string): Promise<boolean> => {
  try {
    const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
    await tauriInvoke("git_reset", { repoPath: resolvedRepoPath, filePath });
    emitGitChanged({
      repoPath: resolvedRepoPath,
      filePath,
      scopes: ["working-tree"],
      source: "unstage-file",
    });
    return true;
  } catch (error) {
    console.error("Failed to unstage file:", error);
    return false;
  }
};

/** Rejects with the Core failure so callers can show the reason and reconcile status. */
export const setFilesStaged = async (
  repoPath: string,
  filePaths: string[],
  staged: boolean,
): Promise<boolean> => {
  const uniqueFilePaths = [...new Set(filePaths)];
  if (uniqueFilePaths.length === 0) return true;

  const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
  return enqueueStagingWrite(resolvedRepoPath, async () => {
    await tauriInvoke("git.write", {
      repoPath: resolvedRepoPath,
      operation: staged ? "stage" : "unstage",
      paths: uniqueFilePaths,
    });
    emitGitChanged({
      repoPath: resolvedRepoPath,
      scopes: ["working-tree"],
      source: staged ? "stage-files" : "unstage-files",
    });
    return true;
  });
};

export const stageAllFiles = async (repoPath: string): Promise<boolean> => {
  try {
    const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
    await tauriInvoke("git_add_all", { repoPath: resolvedRepoPath });
    emitGitChanged({
      repoPath: resolvedRepoPath,
      scopes: ["working-tree"],
      source: "stage-all",
    });
    return true;
  } catch (error) {
    console.error("Failed to stage all files:", error);
    return false;
  }
};

export const unstageAllFiles = async (repoPath: string): Promise<boolean> => {
  try {
    const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
    await tauriInvoke("git_reset_all", { repoPath: resolvedRepoPath });
    emitGitChanged({
      repoPath: resolvedRepoPath,
      scopes: ["working-tree"],
      source: "unstage-all",
    });
    return true;
  } catch (error) {
    console.error("Failed to unstage all files:", error);
    return false;
  }
};

export const stageHunk = async (repoPath: string, hunk: GitHunk): Promise<boolean> => {
  try {
    const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
    await tauriInvoke("git_stage_hunk", { repoPath: resolvedRepoPath, hunk });
    emitGitChanged({
      repoPath: resolvedRepoPath,
      filePath: hunk.file_path,
      scopes: ["working-tree"],
      source: "stage-hunk",
    });
    return true;
  } catch (error) {
    console.error("Failed to stage hunk:", error);
    return false;
  }
};

export const unstageHunk = async (repoPath: string, hunk: GitHunk): Promise<boolean> => {
  try {
    const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
    await tauriInvoke("git_unstage_hunk", { repoPath: resolvedRepoPath, hunk });
    emitGitChanged({
      repoPath: resolvedRepoPath,
      filePath: hunk.file_path,
      scopes: ["working-tree"],
      source: "unstage-hunk",
    });
    return true;
  } catch (error) {
    console.error("Failed to unstage hunk:", error);
    return false;
  }
};

/**
 * Reverse-applies one working-tree hunk, discarding only that block's unstaged
 * edits. The hunk must come from an index-to-worktree patch of `repoPath`;
 * Git rejects it without writing when the file no longer matches.
 */
/** `"unsafe"` means Core refused because a Git filter or working-tree-encoding applies. */
export const discardHunk = async (repoPath: string, hunk: GitHunk): Promise<boolean | "unsafe"> => {
  try {
    const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
    await tauriInvoke("git_discard_hunk", { repoPath: resolvedRepoPath, hunk });
    emitGitChanged({
      repoPath: resolvedRepoPath,
      filePath: hunk.file_path,
      scopes: ["working-tree"],
      source: "discard-hunk",
    });
    return true;
  } catch (error) {
    if ((error instanceof Error ? error.message : String(error)).includes("GIT_HUNK_ROLLBACK_UNSAFE")) {
      return "unsafe";
    }
    console.error("Failed to discard hunk:", error);
    return false;
  }
};

export const discardAllChanges = async (repoPath: string): Promise<boolean> => {
  try {
    const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
    await tauriInvoke("git_discard_all_changes", { repoPath: resolvedRepoPath });
    emitGitChanged({
      repoPath: resolvedRepoPath,
      scopes: ["working-tree"],
      source: "discard-all",
    });
    return true;
  } catch (error) {
    console.error("Failed to discard all changes:", error);
    return false;
  }
};

export const discardFileChanges = async (repoPath: string, filePath: string): Promise<boolean> => {
  try {
    const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
    await tauriInvoke("git_discard_file_changes", { repoPath: resolvedRepoPath, filePath });
    emitGitChanged({
      repoPath: resolvedRepoPath,
      filePath,
      scopes: ["working-tree"],
      source: "discard-file",
    });
    return true;
  } catch (error) {
    console.error("Failed to discard file changes:", error);
    return false;
  }
};

export interface GitRollbackChange {
  path: string;
  originalPath?: string;
  status: string;
}

interface GitRollbackStep {
  operation: "unstage" | "discard" | "discardAll";
  paths: string[];
}

export const rollbackFilesChanges = async (
  repoPath: string,
  changes: GitRollbackChange[],
): Promise<void> => {
  if (changes.length === 0) return;
  const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
  await enqueueStagingWrite(resolvedRepoPath, async () => {
    const { steps } = await tauriInvoke<{ steps: GitRollbackStep[] }>("git.rollbackPrepare", {
      repoPath: resolvedRepoPath,
      changes,
      deleteAddedFiles: false,
    });
    let attempted = false;
    try {
      for (const step of steps) {
        attempted = true;
        await tauriInvoke("git.write", {
          repoPath: resolvedRepoPath,
          operation: step.operation,
          paths: step.paths,
        });
      }
    } finally {
      // Git can modify some paths before reporting an error.
      if (attempted)
        emitGitChanged({
          repoPath: resolvedRepoPath,
          scopes: ["working-tree"],
          source: "rollback-files",
        });
    }
  });
};

const addPathsToIgnoreFile = async (
  repoPath: string,
  filePaths: string[],
  operation: "ignore" | "exclude",
): Promise<boolean> => {
  const uniqueFilePaths = [...new Set(filePaths)];
  if (uniqueFilePaths.length === 0) return true;

  try {
    const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
    await tauriInvoke("git.write", {
      repoPath: resolvedRepoPath,
      operation,
      paths: uniqueFilePaths,
    });
    emitGitChanged({
      repoPath: resolvedRepoPath,
      scopes: ["working-tree"],
      source: operation === "ignore" ? "add-to-gitignore" : "add-to-git-exclude",
    });
    return true;
  } catch (error) {
    console.error(
      `Failed to add paths to ${operation === "ignore" ? ".gitignore" : ".git/info/exclude"}:`,
      error,
    );
    return false;
  }
};

export const addPathsToGitignore = (repoPath: string, filePaths: string[]): Promise<boolean> =>
  addPathsToIgnoreFile(repoPath, filePaths, "ignore");

export const addPathsToLocalGitExclude = (
  repoPath: string,
  filePaths: string[],
): Promise<boolean> => addPathsToIgnoreFile(repoPath, filePaths, "exclude");

export const initRepository = async (repoPath: string): Promise<boolean> => {
  try {
    const result = await initializeGitRepository(repoPath);
    return result.isRepository;
  } catch (error) {
    console.error("Failed to initialize repository:", error);
    return false;
  }
};

export interface GitCommitSelectionRepository {
  root: string;
  selected: GitRollbackChange[];
}

/** Hold the existing per-repository write queues while Core prepares every index. */
export async function prepareCommitSelection(
  repositories: GitCommitSelectionRepository[],
  operationId: string,
  signal: AbortSignal,
): Promise<void> {
  const resolved = await Promise.all(
    repositories.map(async (repository) => ({
      root: await resolveRepositoryPathOrThrow(repository.root),
      selected: repository.selected,
    })),
  );
  const unique = new Map<string, GitCommitSelectionRepository>();
  for (const repository of resolved) {
    if (unique.has(repository.root)) throw new Error("GIT_COMMIT_SELECTION_STALE");
    unique.set(repository.root, repository);
  }
  const ordered = [...unique.values()].sort((left, right) => left.root.localeCompare(right.root));
  const run = async (index: number): Promise<void> => {
    if (signal.aborted) throw new DOMException("Cancelled", "AbortError");
    if (index < ordered.length) {
      await enqueueStagingWrite(ordered[index]!.root, () => run(index + 1));
      return;
    }
    const cancel = () => {
      void tauriInvoke("core_cancel", { operationId }).catch(() => {
        frontendTrace("warn", "git.staging", "Could not cancel commit selection");
      });
    };
    signal.addEventListener("abort", cancel, { once: true });
    let reserved = false;
    let attempted = false;
    try {
      if (signal.aborted) throw new DOMException("Cancelled", "AbortError");
      reserved = await tauriInvoke<boolean>("core_reserve_commit_selection", { operationId });
      if (!reserved) throw new Error("GIT_COMMIT_SELECTION_STALE");
      if (signal.aborted) throw new DOMException("Cancelled", "AbortError");
      attempted = true;
      await tauriInvoke(
        "git.prepareCommitSelection",
        { repositories: ordered, operationId },
        { gitExecutionSource: "user" },
      );
      if (signal.aborted) throw new DOMException("Cancelled", "AbortError");
    } finally {
      signal.removeEventListener("abort", cancel);
      if (reserved) {
        await tauriInvoke("core_release_commit_selection", { operationId }).catch(() => {
          frontendTrace("warn", "git.staging", "Could not release commit selection");
        });
      }
      // A failed or cancelled request can have already changed an index.
      if (attempted)
        for (const repository of ordered)
          emitGitChanged({
            repoPath: repository.root,
            scopes: ["working-tree"],
            source: "prepare-commit-selection",
          });
    }
  };
  await run(0);
}

/** Reconcile only selected additions that are missing after deletion. */
export async function reconcileDeletedSelection(
  repoPath: string,
  changes: GitRollbackChange[],
): Promise<void> {
  const root = await resolveRepositoryPathOrThrow(repoPath);
  await enqueueStagingWrite(root, async () => {
    try {
      await tauriInvoke(
        "git.reconcileDeletedSelection",
        { root, changes },
        { gitExecutionSource: "user" },
      );
    } finally {
      emitGitChanged({
        repoPath: root,
        scopes: ["working-tree"],
        source: "reconcile-deleted-selection",
      });
    }
  });
}
