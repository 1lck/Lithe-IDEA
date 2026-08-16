import { invoke as tauriInvoke } from "@/platform/tauri-core";
import { emitGitChanged } from "../events/git-events";
import { runGitRead } from "../runtime/git-read-coordinator";
import {
  isNotGitRepositoryError,
  resolveRepositoryPath,
  resolveRepositoryPathOrThrow,
} from "./git-repo-api";

interface CheckoutResult {
  success: boolean;
  hasChanges: boolean;
  message: string;
}

interface CheckoutPreflightResult {
  blocked: boolean;
  blockingPaths: string[];
}

const checkoutErrorMessage = (error: unknown): string => {
  const message = error instanceof Error ? error.message : String(error);
  return message.trim() || "Failed to checkout branch";
};

const blockingChangesMessage = (blockingPaths: string[]): string => {
  const listed = blockingPaths.slice(0, 3).join(", ");
  const remaining = blockingPaths.length - Math.min(blockingPaths.length, 3);
  const suffix = remaining > 0 ? ` (+${remaining} more)` : "";
  return `Local changes would be overwritten by switching branches: ${listed}${suffix}`;
};

export const getBranches = async (repoPath: string): Promise<string[]> => {
  try {
    const resolvedRepoPath = await resolveRepositoryPath(repoPath);
    if (!resolvedRepoPath) {
      return [];
    }

    return await runGitRead(resolvedRepoPath, "branches", () =>
      tauriInvoke<string[]>("git_branches", { repoPath: resolvedRepoPath }),
    );
  } catch (error) {
    if (!isNotGitRepositoryError(error)) {
      console.error("Failed to get branches:", error);
    }
    return [];
  }
};

export const checkoutBranch = async (
  repoPath: string,
  branchName: string,
): Promise<CheckoutResult> => {
  try {
    const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);

    const preflight = await tauriInvoke<CheckoutPreflightResult>("git_checkout_preflight", {
      repoPath: resolvedRepoPath,
      branchName,
    });
    if (preflight.blocked) {
      return {
        success: false,
        hasChanges: true,
        message: blockingChangesMessage(preflight.blockingPaths),
      };
    }

    const result = await tauriInvoke<CheckoutResult>("git_checkout", {
      repoPath: resolvedRepoPath,
      branchName,
    });
    if (result.success) {
      emitGitChanged({
        repoPath: resolvedRepoPath,
        scopes: ["working-tree", "history", "refs"],
        source: "checkout-branch",
      });
    }
    return result;
  } catch (error) {
    console.error("Failed to checkout branch:", error);
    return {
      success: false,
      hasChanges: false,
      message: checkoutErrorMessage(error),
    };
  }
};

export const createBranch = async (
  repoPath: string,
  branchName: string,
  fromBranch?: string,
): Promise<boolean> => {
  try {
    const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
    await tauriInvoke("git_create_branch", {
      repoPath: resolvedRepoPath,
      branchName,
      fromBranch,
    });
    emitGitChanged({
      repoPath: resolvedRepoPath,
      scopes: ["refs"],
      source: "create-branch",
    });
    return true;
  } catch (error) {
    console.error("Failed to create branch:", error);
    return false;
  }
};

export const deleteBranch = async (repoPath: string, branchName: string): Promise<boolean> => {
  try {
    const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
    await tauriInvoke("git_delete_branch", { repoPath: resolvedRepoPath, branchName });
    emitGitChanged({
      repoPath: resolvedRepoPath,
      scopes: ["refs"],
      source: "delete-branch",
    });
    return true;
  } catch (error) {
    console.error("Failed to delete branch:", error);
    return false;
  }
};
