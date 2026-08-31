import { invoke as tauriInvoke } from "@/platform/tauri-core";
import type { GitPullPreflight, GitRemote, PullStrategy } from "../types/git.types";
import { emitGitChanged } from "../events/git-events";
import { GitPullWorkflow } from "../hooks/git-pull-workflow";
import { runGitRead } from "../runtime/git-read-coordinator";
import { getBranches } from "./git-branches-api";
import { getGitHistory } from "./git-commits-api";
import { getOperationState } from "./git-integration-api";
import { executeGitPush } from "./git-push-api";
import { getGitStatus } from "./git-status-api";
import {
  isNotGitRepositoryError,
  resolveRepositoryPath,
  resolveRepositoryPathOrThrow,
} from "./git-repo-api";

export interface GitRemoteActionResult {
  success: boolean;
  error?: string;
}

export const getRemotes = async (repoPath: string): Promise<GitRemote[]> => {
  try {
    const resolvedRepoPath = await resolveRepositoryPath(repoPath);
    if (!resolvedRepoPath) {
      return [];
    }

    return await runGitRead(resolvedRepoPath, "remotes", () =>
      tauriInvoke<GitRemote[]>("git_get_remotes", {
        repoPath: resolvedRepoPath,
      }),
    );
  } catch (error) {
    if (!isNotGitRepositoryError(error)) {
      console.error("Failed to get remotes:", error);
    }
    return [];
  }
};

export const addRemote = async (repoPath: string, name: string, url: string): Promise<boolean> => {
  try {
    const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
    await tauriInvoke("git_add_remote", { repoPath: resolvedRepoPath, name, url });
    emitGitChanged({
      repoPath: resolvedRepoPath,
      scopes: ["remotes"],
      source: "add-remote",
    });
    return true;
  } catch (error) {
    console.error("Failed to add remote:", error);
    return false;
  }
};

export const removeRemote = async (repoPath: string, name: string): Promise<boolean> => {
  try {
    const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
    await tauriInvoke("git_remove_remote", { repoPath: resolvedRepoPath, name });
    emitGitChanged({
      repoPath: resolvedRepoPath,
      scopes: ["remotes"],
      source: "remove-remote",
    });
    return true;
  } catch (error) {
    console.error("Failed to remove remote:", error);
    return false;
  }
};

export const deleteRemoteBranch = async (
  repoPath: string,
  remote: string,
  branchName: string,
): Promise<void> => {
  const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
  await tauriInvoke("git.command", {
    repoPath: resolvedRepoPath,
    arguments: ["push", "--delete", "--", remote, `refs/heads/${branchName}`],
  });
  emitGitChanged({
    repoPath: resolvedRepoPath,
    scopes: ["history", "refs", "remotes"],
    source: "delete-remote-branch",
  });
};

export const pushChanges = async (
  repoPath: string,
  branch?: string,
  _remote: string = "origin",
): Promise<GitRemoteActionResult> => {
  try {
    await executeGitPush(repoPath, { reference: branch });
    return { success: true };
  } catch (error) {
    console.error("Failed to push changes:", error);
    return {
      success: false,
      error: error instanceof Error ? error.message : String(error),
    };
  }
};

export const getPullPreflight = async (repoPath: string): Promise<GitPullPreflight> => {
  const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
  return tauriInvoke<GitPullPreflight>("git.pullPreflight", {
    repoPath: resolvedRepoPath,
  });
};

export const executePullChanges = async (
  repoPath: string,
  strategy: PullStrategy,
): Promise<GitRemoteActionResult> => {
  try {
    const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
    await tauriInvoke("git_pull", { repoPath: resolvedRepoPath, mode: strategy });
    return { success: true };
  } catch (error) {
    console.error("Failed to pull changes:", error);
    return {
      success: false,
      error: error instanceof Error ? error.message : String(error),
    };
  }
};

export const fetchChanges = async (repoPath: string): Promise<GitRemoteActionResult> => {
  try {
    const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
    await tauriInvoke("git_fetch", { repoPath: resolvedRepoPath });
    emitGitChanged({
      repoPath: resolvedRepoPath,
      scopes: ["refs", "remotes"],
      source: "fetch",
    });
    return { success: true };
  } catch (error) {
    console.error("Failed to fetch changes:", error);
    return {
      success: false,
      error: error instanceof Error ? error.message : String(error),
    };
  }
};

const pullWorkflows = new Map<string, GitPullWorkflow>();

/** Returns the shared Pull coordinator for one repository. */
export const getGitPullWorkflow = (repoPath: string): GitPullWorkflow => {
  const existingWorkflow = pullWorkflows.get(repoPath);
  if (existingWorkflow) return existingWorkflow;

  const workflow = new GitPullWorkflow({
    fetch: fetchChanges,
    preflight: getPullPreflight,
    pull: executePullChanges,
    operationState: getOperationState,
  });
  pullWorkflows.set(repoPath, workflow);
  return workflow;
};

/**
 * Safe compatibility entry point for non-Source-Control callers. Divergence
 * cancels because only the Source Control workflow can present the choice UI.
 */
export const pullChanges = async (repoPath: string): Promise<GitRemoteActionResult> => {
  const workflow = getGitPullWorkflow(repoPath);
  const unsubscribe = workflow.subscribe(() => {
    if (workflow.getSnapshot().pendingPreflight) {
      workflow.chooseStrategy(null);
    }
  });
  const resultPromise = workflow.run(repoPath, {
    refresh: async () => {
      const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
      // Cache invalidation must precede the explicit reads below; otherwise a
      // failed or successful Pull could refresh the UI from stale snapshots.
      emitGitChanged({
        repoPath: resolvedRepoPath,
        scopes: ["working-tree", "history", "refs", "remotes"],
        source: "pull-finished",
      });
      await Promise.all([
        getGitStatus(resolvedRepoPath),
        getGitHistory(resolvedRepoPath, 50),
        getBranches(resolvedRepoPath),
        getRemotes(resolvedRepoPath),
      ]);
    },
  });
  try {
    const result = await resultPromise;
    return result.status === "pulled"
      ? { success: true }
      : {
          success: false,
          error:
            result.status === "cancelled"
              ? "Branches have diverged. Open Source Control and choose Merge or Rebase."
              : result.message,
        };
  } finally {
    unsubscribe();
  }
};
