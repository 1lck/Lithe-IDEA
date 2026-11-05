import { invoke as tauriInvoke } from "@/platform/tauri-core";
import type { GitTag } from "../types/git.types";
import { emitGitChanged } from "../events/git-events";
import { runGitRead } from "../runtime/git-read-coordinator";
import {
  isNotGitRepositoryError,
  resolveRepositoryPath,
  resolveRepositoryPathOrThrow,
} from "./git-repo-api";
import type { GitRemoteActionResult } from "./git-remotes-api";

interface CheckoutTagResult {
  success: boolean;
  hasChanges: boolean;
  message: string;
}

/** Shared `git.write` response fields needed to detect a failed Git invocation. */
interface GitWriteResult {
  output?: string;
  exitCode?: number;
}

/**
 * Core reports a failure that happens after a Git subprocess starts on the
 * response instead of rejecting the command. Surface it as an error so a tag
 * write never claims success for a failed Git invocation.
 */
function requireSuccessfulTagWrite(result: GitWriteResult | null | undefined, fallback: string): void {
  if (typeof result?.exitCode === "number" && result.exitCode !== 0) {
    throw new Error(result.output?.trim() || fallback);
  }
}

export const getTags = async (repoPath: string): Promise<GitTag[]> => {
  try {
    const resolvedRepoPath = await resolveRepositoryPath(repoPath);
    if (!resolvedRepoPath) {
      return [];
    }

    return await runGitRead(resolvedRepoPath, "tags", () =>
      tauriInvoke<GitTag[]>("git_get_tags", { repoPath: resolvedRepoPath }),
    );
  } catch (error) {
    if (!isNotGitRepositoryError(error)) {
      console.error("Failed to get tags:", error);
    }
    return [];
  }
};

export const createTag = async (
  repoPath: string,
  name: string,
  message?: string,
  commit?: string,
  signed = false,
  options?: { lightweight?: boolean },
): Promise<boolean> => {
  try {
    const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
    // Legacy Windows semantics: an empty target means HEAD and an empty message
    // means a lightweight tag. Core's typed createTag requires an explicit
    // revision and treats any explicit message as annotated, so normalize here.
    const revision = commit?.trim() ? commit : "HEAD";
    const tagMessage = message?.trim() ? message : undefined;
    const result = await tauriInvoke<GitWriteResult>("git.write", {
      repoPath: resolvedRepoPath,
      operation: "createTag",
      name,
      revision,
      signed,
      ...(tagMessage === undefined ? {} : { message: tagMessage }),
      ...(options?.lightweight ? { lightweight: true } : {}),
    });
    requireSuccessfulTagWrite(result, "Git tag creation failed");
    emitGitChanged({
      repoPath: resolvedRepoPath,
      scopes: ["refs"],
      source: "create-tag",
    });
    return true;
  } catch (error) {
    // The exported signature reports only success/failure; keep Git's reason in
    // the console log so a failed tag creation is diagnosable.
    console.error("Failed to create tag:", error);
    return false;
  }
};

export const pushTag = async (
  repoPath: string,
  name: string,
  remote: string,
): Promise<GitRemoteActionResult> => {
  try {
    const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
    await tauriInvoke("git_push_tag", { repoPath: resolvedRepoPath, name, remote });
    emitGitChanged({
      repoPath: resolvedRepoPath,
      scopes: ["refs", "remotes"],
      source: "push-tag",
    });
    return { success: true };
  } catch (error) {
    console.error("Failed to push tag:", error);
    return {
      success: false,
      error: error instanceof Error ? error.message : String(error),
    };
  }
};

export const deleteRemoteTag = async (
  repoPath: string,
  name: string,
  remote: string,
): Promise<GitRemoteActionResult> => {
  try {
    const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
    await tauriInvoke("git_delete_remote_tag", { repoPath: resolvedRepoPath, name, remote });
    emitGitChanged({
      repoPath: resolvedRepoPath,
      scopes: ["refs", "remotes"],
      source: "delete-remote-tag",
    });
    return { success: true };
  } catch (error) {
    console.error("Failed to delete remote tag:", error);
    return {
      success: false,
      error: error instanceof Error ? error.message : String(error),
    };
  }
};

export const checkoutTag = async (repoPath: string, name: string): Promise<CheckoutTagResult> => {
  try {
    const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
    const result = await tauriInvoke<CheckoutTagResult>("git_checkout_tag", {
      repoPath: resolvedRepoPath,
      name,
    });
    if (result.success) {
      emitGitChanged({
        repoPath: resolvedRepoPath,
        scopes: ["working-tree", "history", "refs"],
        source: "checkout-tag",
      });
    }
    return result;
  } catch (error) {
    console.error("Failed to checkout tag:", error);
    return {
      success: false,
      hasChanges: false,
      message: error instanceof Error ? error.message : String(error),
    };
  }
};

export const deleteTag = async (repoPath: string, name: string): Promise<boolean> => {
  try {
    const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
    const result = await tauriInvoke<GitWriteResult>("git.write", {
      repoPath: resolvedRepoPath,
      operation: "deleteTag",
      name,
    });
    requireSuccessfulTagWrite(result, "Git tag deletion failed");
    emitGitChanged({
      repoPath: resolvedRepoPath,
      scopes: ["refs"],
      source: "delete-tag",
    });
    return true;
  } catch (error) {
    console.error("Failed to delete tag:", error);
    return false;
  }
};
