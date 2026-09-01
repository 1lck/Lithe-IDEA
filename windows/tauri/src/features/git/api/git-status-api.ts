import { invoke as tauriInvoke } from "@/platform/tauri-core";
import { emitGitChanged } from "../events/git-events";
import { registerGitCacheInvalidator } from "../runtime/git-cache-registry";
import type { GitHunk, GitStatus } from "../types/git.types";
import {
  isNotGitRepositoryError,
  resolveRepositoryPath,
  resolveRepositoryPathOrThrow,
} from "./git-repo-api";

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
  inFlightGitStatusRequests.delete(repoPath);
});

export const getGitStatus = async (repoPath: string): Promise<GitStatus | null> => {
  let resolvedRepoPath: string | null;

  try {
    resolvedRepoPath = await resolveRepositoryPath(repoPath);
  } catch (error) {
    if (!isNotGitRepositoryError(error)) {
      console.error("Failed to get git status:", error);
    }
    return null;
  }

  if (!resolvedRepoPath) {
    return null;
  }

  const existingRequest = inFlightGitStatusRequests.get(resolvedRepoPath);
  if (existingRequest) {
    return existingRequest;
  }

  const generation = gitStatusGenerations.get(resolvedRepoPath) ?? 0;
  if (!gitStatusGenerations.has(resolvedRepoPath)) {
    gitStatusGenerations.set(resolvedRepoPath, generation);
  }
  const request = tauriInvoke<GitStatus>("git_status", { repoPath: resolvedRepoPath })
    .then((status) => {
      if (generation !== (gitStatusGenerations.get(resolvedRepoPath) ?? 0)) {
        return getGitStatus(resolvedRepoPath);
      }
      return status;
    })
    .catch((error) => {
      if (!isNotGitRepositoryError(error)) {
        console.error("Failed to get git status:", error);
      }
      return null;
    })
    .finally(() => {
      if (inFlightGitStatusRequests.get(resolvedRepoPath) === request) {
        inFlightGitStatusRequests.delete(resolvedRepoPath);
      }
    });

  inFlightGitStatusRequests.set(resolvedRepoPath, request);
  return request;
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

export const setFilesStaged = async (
  repoPath: string,
  filePaths: string[],
  staged: boolean,
): Promise<boolean> => {
  const uniqueFilePaths = [...new Set(filePaths)];
  if (uniqueFilePaths.length === 0) return true;

  try {
    const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
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
  } catch (error) {
    console.error(`Failed to ${staged ? "stage" : "unstage"} files:`, error);
    return false;
  }
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
    await tauriInvoke("git_init", { repoPath });
    emitGitChanged({
      repoPath,
      scopes: ["repository", "working-tree", "refs"],
      source: "initialize-repository",
    });
    return true;
  } catch (error) {
    console.error("Failed to initialize repository:", error);
    return false;
  }
};
