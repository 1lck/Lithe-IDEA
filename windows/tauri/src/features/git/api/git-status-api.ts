import type { GitExecutionSource } from "@/platform/git-execution-events";
import { invoke as tauriInvoke } from "@/platform/tauri-core";
import { emitGitChanged } from "../events/git-events";
import { createRepositoryWriteQueue } from "../services/git-operation-coordinator";
import { registerGitCacheInvalidator } from "../runtime/git-cache-registry";
import { initializeGitRepository } from "./git-setup-api";
import type { GitFile, GitHunk, GitStatus } from "../types/git.types";
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
const queryGitStatus = async (repoPath: string, source: GitExecutionSource = "unknown"): Promise<GitStatus | null> => {
  const resolvedRepoPath = await resolveRepositoryPath(repoPath);

  if (!resolvedRepoPath) {
    return null;
  }

  const requestKey = `${resolvedRepoPath}\0${source}`;
  const existingRequest = inFlightGitStatusRequests.get(requestKey);
  if (existingRequest) {
    return existingRequest;
  }

  const generation = gitStatusGenerations.get(resolvedRepoPath) ?? 0;
  if (!gitStatusGenerations.has(resolvedRepoPath)) {
    gitStatusGenerations.set(resolvedRepoPath, generation);
  }
  const request = (source === "unknown"
    ? tauriInvoke<GitStatus>("git_status", { repoPath: resolvedRepoPath })
    : tauriInvoke<GitStatus>("git_status", { repoPath: resolvedRepoPath }, { gitExecutionSource: source }))
    .then((status) => {
      if (generation !== (gitStatusGenerations.get(resolvedRepoPath) ?? 0)) {
        return queryGitStatus(resolvedRepoPath, source);
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

function getRepoLabel(repoPath: string): string {
  const normalized = repoPath.replace(/\\/g, "/").replace(/\/+$/, "");
  return normalized.split("/").pop() || normalized || "repository";
}

function decorateWorkspaceFile(file: GitFile, repoPath: string, prefix: string): GitFile {
  return {
    ...file,
    path: `${prefix}/${file.path}`,
    originalPath: file.originalPath ? `${prefix}/${file.originalPath}` : undefined,
    repositoryPath: repoPath,
    repositoryRelativePath: file.path,
    repositoryOriginalRelativePath: file.originalPath,
  };
}

export const getWorkspaceGitStatus = async (
  repoPaths: readonly string[],
  activeRepoPath?: string,
  source: GitExecutionSource = "unknown",
): Promise<GitStatus | null> => {
  const normalizedRepoPaths = normalizeStatusRepoPaths(repoPaths);
  if (normalizedRepoPaths.length === 0) return null;
  // These paths are already discovered/selected repositories. A null response
  // is an unavailable snapshot, not evidence that the workspace has no changes.
  const readStatus = async (repoPath: string): Promise<GitStatus> => {
    const status = await queryGitStatus(repoPath, source);
    if (!status) throw new Error("Git status query returned no snapshot");
    return status;
  };
  if (normalizedRepoPaths.length === 1) return readStatus(normalizedRepoPaths[0]!);

  const statuses = await Promise.all(
    normalizedRepoPaths.map(async (repoPath) => ({
      repoPath,
      status: await readStatus(repoPath),
    })),
  );
  const duplicateLabels = new Set<string>();
  const seenLabels = new Set<string>();
  for (const repoPath of normalizedRepoPaths) {
    const label = getRepoLabel(repoPath);
    if (seenLabels.has(label)) duplicateLabels.add(label);
    seenLabels.add(label);
  }

  const files = statuses.flatMap(({ repoPath, status }) => {
    const label = getRepoLabel(repoPath);
    const prefix = duplicateLabels.has(label) ? repoPath.replace(/\\/g, "/") : label;
    return status.files.map((file) => decorateWorkspaceFile(file, repoPath, prefix));
  });

  const activeStatus =
    statuses.find((entry) => entry.repoPath === activeRepoPath)?.status ??
    statuses[0]!.status;
  return {
    branch: activeStatus.branch,
    ahead: activeStatus.ahead,
    behind: activeStatus.behind,
    files,
  };
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

export const rollbackFilesChanges = async (
  repoPath: string,
  filePaths: string[],
): Promise<void> => {
  const uniqueFilePaths = [...new Set(filePaths)];
  if (uniqueFilePaths.length === 0) return;

  const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
  await tauriInvoke("git.write", {
    repoPath: resolvedRepoPath,
    operation: "discardAll",
    paths: uniqueFilePaths,
  });
  emitGitChanged({
    repoPath: resolvedRepoPath,
    scopes: ["working-tree"],
    source: "rollback-files",
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
