import { invoke as tauriInvoke } from "@/platform/tauri-core";
import { emitGitChanged } from "../events/git-events";
import { runGitRead } from "../runtime/git-read-coordinator";
import {
  isNotGitRepositoryError,
  resolveRepositoryPath,
  resolveRepositoryPathOrThrow,
} from "./git-repo-api";
import type { GitReference } from "../types/git.types";
import { referencePayload, type GitReferenceInput } from "./git-reference-payload";
import { executeGitPush } from "./git-push-api";

export interface CheckoutResult {
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

const localBranchReference = (branchName: string): string =>
  branchName.startsWith("refs/heads/") ? branchName : `refs/heads/${branchName}`;

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
): Promise<CheckoutResult> => checkoutReference(repoPath, localBranchReference(branchName), "local");

export const checkoutReference = async (
  repoPath: string,
  reference: GitReferenceInput,
  referenceKind?: "local" | "remote" | "tag",
): Promise<CheckoutResult> => {
  try {
    const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);

    const preflight = await tauriInvoke<CheckoutPreflightResult>("git.checkoutPreflight", {
      repoPath: resolvedRepoPath,
      ...referencePayload(reference),
    });
    if (preflight.blockingPaths.length > 0) {
      return {
        success: false,
        hasChanges: true,
        message: blockingChangesMessage(preflight.blockingPaths),
      };
    }

    await tauriInvoke("git.write", {
      repoPath: resolvedRepoPath,
      operation: "checkout",
      ...referencePayload(reference),
      ...(typeof reference === "string" && referenceKind ? { referenceKind } : {}),
    });
    emitGitChanged({
      repoPath: resolvedRepoPath,
      scopes: ["working-tree", "history", "refs"],
      source: "checkout-branch",
    });
    return { success: true, hasChanges: false, message: "" };
  } catch (error) {
    console.error("Failed to checkout branch:", error);
    return {
      success: false,
      hasChanges: false,
      message: checkoutErrorMessage(error),
    };
  }
};

export const checkoutRemoteBranch = async (
  repoPath: string,
  reference: string,
): Promise<CheckoutResult> => checkoutReference(repoPath, reference, "remote");

export const checkoutGitReference = async (
  repoPath: string,
  reference: GitReference,
): Promise<CheckoutResult> => checkoutReference(repoPath, reference);

export const createBranch = async (
  repoPath: string,
  branchName: string,
  from?: string | GitReference,
): Promise<boolean> => {
  try {
    const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
    const source = typeof from === "string" ? localBranchReference(from) : (from ?? "HEAD");
    await tauriInvoke("git.write", {
      repoPath: resolvedRepoPath,
      operation: "createBranch",
      name: branchName,
      ...referencePayload(source),
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

export const createAndCheckoutBranch = async (
  repoPath: string,
  branchName: string,
  reference: GitReferenceInput,
): Promise<void> => {
  const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
  await tauriInvoke("git.write", {
    repoPath: resolvedRepoPath,
    operation: "createBranch",
    name: branchName,
    ...referencePayload(reference),
    checkout: true,
  });
  emitGitChanged({
    repoPath: resolvedRepoPath,
    scopes: ["working-tree", "history", "refs"],
    source: "create-and-checkout-branch",
  });
};

export const renameBranch = async (
  repoPath: string,
  branchName: string,
  newBranchName: string,
): Promise<void> => {
  const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
  await tauriInvoke("git.write", {
    repoPath: resolvedRepoPath,
    operation: "renameBranch",
    reference: localBranchReference(branchName),
    name: newBranchName,
  });
  emitGitChanged({
    repoPath: resolvedRepoPath,
    scopes: ["history", "refs"],
    source: "rename-branch",
  });
};

export const pushBranch = async (repoPath: string, branchName: string): Promise<void> => {
  await executeGitPush(repoPath, { reference: localBranchReference(branchName) });
};

export const setBranchUpstream = async (
  repoPath: string,
  branchName: string,
  upstreamShortName: string,
): Promise<void> => {
  const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
  await tauriInvoke("git.command", {
    repoPath: resolvedRepoPath,
    arguments: ["branch", "--set-upstream-to", upstreamShortName, branchName],
  });
  emitGitChanged({
    repoPath: resolvedRepoPath,
    scopes: ["history", "refs", "remotes"],
    source: "set-branch-upstream",
  });
};

export const unsetBranchUpstream = async (
  repoPath: string,
  branchName: string,
): Promise<void> => {
  const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
  await tauriInvoke("git.command", {
    repoPath: resolvedRepoPath,
    arguments: ["branch", "--unset-upstream", branchName],
  });
  emitGitChanged({
    repoPath: resolvedRepoPath,
    scopes: ["history", "refs", "remotes"],
    source: "unset-branch-upstream",
  });
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
