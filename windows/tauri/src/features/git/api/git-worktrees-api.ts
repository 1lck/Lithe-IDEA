import { invoke as tauriInvoke } from "@/platform/tauri-core";
import type { GitReference, GitWorktree } from "../types/git.types";
import { emitGitChanged } from "../events/git-events";
import { runGitRead } from "../runtime/git-read-coordinator";
import {
  isNotGitRepositoryError,
  resolveRepositoryPath,
  resolveRepositoryPathOrThrow,
} from "./git-repo-api";

interface CoreGitWorktree {
  path: string;
  head: string;
  branch: string | null;
  isCurrent: boolean;
  isPrimary: boolean;
  isBare: boolean;
  isDetached: boolean;
  isLocked: boolean;
  lockReason: string | null;
  isPrunable: boolean;
  pruneReason: string | null;
}

export async function readWorktrees(repoPath: string): Promise<GitWorktree[]> {
  const root = await resolveRepositoryPathOrThrow(repoPath);
  const result = await runGitRead(root, "worktrees", () =>
    tauriInvoke<{ worktrees: CoreGitWorktree[] }>("git.worktrees", { root }),
  );
  return result.worktrees.map((entry) => ({
    path: entry.path,
    head: entry.head,
    branch: entry.branch?.replace(/^refs\/heads\//, ""),
    is_current: entry.isCurrent,
    is_primary: entry.isPrimary,
    is_bare: entry.isBare,
    is_detached: entry.isDetached,
    is_locked: entry.isLocked,
    is_prunable: entry.isPrunable,
    locked_reason: entry.lockReason ?? undefined,
    prunable_reason: entry.pruneReason ?? undefined,
  }));
}

export const getWorktrees = async (repoPath: string): Promise<GitWorktree[]> => {
  try {
    const resolvedRepoPath = await resolveRepositoryPath(repoPath);
    if (!resolvedRepoPath) {
      return [];
    }

    return await readWorktrees(resolvedRepoPath);
  } catch (error) {
    if (!isNotGitRepositoryError(error)) {
      console.error("Failed to get worktrees:", error);
    }
    return [];
  }
};

export type GitWorktreeMode = "newBranch" | "existingBranch" | "detached";

export const createWorktree = async (
  repoPath: string,
  options: {
    destination: string;
    worktreeMode: GitWorktreeMode;
    noCheckout: boolean;
    name?: string;
    reference?: GitReference;
    revision?: string;
  },
): Promise<void> => {
  const root = await resolveRepositoryPathOrThrow(repoPath);
  try {
    await tauriInvoke("git.write", {
      root,
      operation: "createWorktree",
      destination: options.destination,
      worktreeMode: options.worktreeMode,
      noCheckout: options.noCheckout,
      ...(options.name ? { name: options.name } : {}),
      ...(options.reference
        ? {
            gitReference: {
              fullName: options.reference.fullName,
              shortName: options.reference.shortName,
              kind: options.reference.kind,
            },
          }
        : {}),
      ...(options.revision ? { revision: options.revision } : {}),
    });
  } finally {
    emitGitChanged({
      repoPath: root,
      scopes: ["repository", "history", "refs"],
      source: "add-worktree",
    });
  }
};

export const addWorktreeFromReference = async (
  repoPath: string,
  path: string,
  branchName: string,
  reference: GitReference,
): Promise<void> => {
  const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
  try {
    await tauriInvoke("git.write", {
      repoPath: resolvedRepoPath,
      operation: "createWorktree",
      destination: path,
      name: branchName,
      gitReference: {
        fullName: reference.fullName,
        shortName: reference.shortName,
        kind: reference.kind,
      },
    });
  } finally {
    emitGitChanged({
      repoPath: resolvedRepoPath,
      scopes: ["repository", "history", "refs"],
      source: "add-reference-worktree",
    });
  }
};

export const removeWorktree = async (
  repoPath: string,
  path: string,
  force: boolean = false,
): Promise<void> => {
  const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
  try {
    await tauriInvoke("git.write", {
      root: resolvedRepoPath,
      operation: "removeWorktree",
      destination: path,
      force,
    });
  } finally {
    emitGitChanged({
      repoPath: resolvedRepoPath,
      scopes: ["repository", "refs"],
      source: "remove-worktree",
    });
  }
};
