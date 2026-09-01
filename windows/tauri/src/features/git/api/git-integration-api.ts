import { invoke as tauriInvoke } from "@/platform/tauri-core";
import { emitGitChanged } from "../events/git-events";
import { resolveRepositoryPathOrThrow } from "./git-repo-api";
import type {
  GitOperationState,
  GitOperationWarning,
  GitReference,
  PullStrategy,
} from "../types/git.types";

type IntegrationOperation = "merge" | "rebase";

interface IntegrationPreflightResult {
  blockingPaths: string[];
  blocksEntirely: boolean;
}

export type IntegrationOutcome =
  | { status: "clean"; warnings?: GitOperationWarning[] }
  | {
      status: "conflicts";
      conflictedPaths: string[];
      deferredAutoStash?: boolean;
      stashRestore?: { stashReference: string };
    }
  | { status: "stopped" }
  | { status: "blocked"; blockingPaths: string[]; blocksEntirely: boolean }
  | { status: "error"; message: string };

export interface OperationResolution {
  ok: boolean;
  message: string;
}

const errorMessage = (error: unknown): string => {
  const message = error instanceof Error ? error.message : String(error);
  return message.trim() || "Git operation failed";
};

const notifyOperationChanged = (repoPath: string, source: string, refreshStashes = false) => {
  emitGitChanged({
    repoPath,
    scopes: refreshStashes
      ? ["working-tree", "history", "refs", "stashes"]
      : ["working-tree", "history", "refs"],
    source,
  });
};

export const getOperationState = async (
  repoPath: string,
): Promise<GitOperationState | null> => {
  const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
  return tauriInvoke<GitOperationState | null>("git_operation_state", {
    repoPath: resolvedRepoPath,
  });
};

export const getConflictMarkerPaths = async (repoPath: string): Promise<string[]> => {
  const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
  const result = await tauriInvoke<{ paths: string[] }>("git_conflict_markers", {
    repoPath: resolvedRepoPath,
  });
  return result.paths;
};

const runIntegration = async (
  repoPath: string,
  reference: string | GitReference,
  operation: IntegrationOperation,
): Promise<IntegrationOutcome> => {
  const command = operation === "merge" ? "git_merge" : "git_rebase";
  try {
    await tauriInvoke(command, {
      repoPath,
      ...(typeof reference === "string"
        ? { branchName: reference }
        : { reference: reference.fullName, referenceKind: reference.kind }),
    });
    notifyOperationChanged(repoPath, `${operation}-completed`);
    return { status: "clean" };
  } catch (error) {
    // A conflict stop exits non-zero like a real failure; the authoritative
    // distinction is whether Git left an operation state behind.
    notifyOperationChanged(repoPath, `${operation}-rejected`);
    try {
      const state = await getOperationState(repoPath);
      if (state?.kind === operation) {
        if (state.conflictedPaths.length > 0) {
          return { status: "conflicts", conflictedPaths: state.conflictedPaths };
        }
        return { status: "stopped" };
      }
    } catch (stateError) {
      console.error(`Failed to read ${operation} state after Git rejected the operation:`, stateError);
    }
    return { status: "error", message: errorMessage(error) };
  }
};

const startIntegration = async (
  repoPath: string,
  reference: string | GitReference,
  operation: IntegrationOperation,
): Promise<IntegrationOutcome> => {
  const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);

  let preflight: IntegrationPreflightResult | null = null;
  try {
    preflight = await tauriInvoke<IntegrationPreflightResult>(
      "git_integration_preflight",
      {
        repoPath: resolvedRepoPath,
        operation,
        ...(typeof reference === "string"
          ? { branchName: reference }
          : { reference: reference.fullName, referenceKind: reference.kind }),
      },
    );
  } catch {
    // A failed preflight must not block the operation itself; Git will still
    // refuse safely when the tree is dirty.
  }

  if (preflight && preflight.blockingPaths.length > 0) {
    return {
      status: "blocked",
      blockingPaths: preflight.blockingPaths,
      blocksEntirely: preflight.blocksEntirely,
    };
  }

  return runIntegration(resolvedRepoPath, reference, operation);
};

export const mergeBranch = (repoPath: string, reference: string | GitReference) =>
  startIntegration(repoPath, reference, "merge");

export const rebaseOntoBranch = (repoPath: string, reference: string | GitReference) =>
  startIntegration(repoPath, reference, "rebase");

export const checkoutAndRebase = async (
  repoPath: string,
  reference: GitReference,
): Promise<IntegrationOutcome> => {
  const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
  try {
    await tauriInvoke("git_checkout_and_rebase", {
      repoPath: resolvedRepoPath,
      reference: reference.fullName,
      referenceKind: reference.kind,
    });
    notifyOperationChanged(resolvedRepoPath, "checkout-and-rebase-completed");
    return { status: "clean" };
  } catch (error) {
    notifyOperationChanged(resolvedRepoPath, "checkout-and-rebase-rejected");
    const state = await getOperationState(resolvedRepoPath).catch(() => null);
    if (state?.kind === "rebase") {
      return state.conflictedPaths.length
        ? { status: "conflicts", conflictedPaths: state.conflictedPaths }
        : { status: "stopped" };
    }
    return { status: "error", message: errorMessage(error) };
  }
};

export const pullRemoteReference = async (
  repoPath: string,
  reference: GitReference,
  strategy: Extract<PullStrategy, "merge" | "rebase">,
  autoStash = false,
): Promise<IntegrationOutcome> => {
  const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
  let preflight: IntegrationPreflightResult | null = null;
  try {
    preflight = await tauriInvoke<IntegrationPreflightResult>("git_integration_preflight", {
      repoPath: resolvedRepoPath,
      operation: strategy,
      reference: reference.fullName,
      referenceKind: reference.kind,
    });
  } catch {
    // Git remains the final authority if a read-only preflight is unavailable.
  }
  if (!autoStash && preflight && preflight.blockingPaths.length > 0) {
    return {
      status: "blocked",
      blockingPaths: preflight.blockingPaths,
      blocksEntirely: preflight.blocksEntirely,
    };
  }
  try {
    const result = await tauriInvoke<{
      stashRestore?: { stashReference: string; conflictedPaths: string[] };
      warnings?: GitOperationWarning[];
    }>("git_pull", {
      repoPath: resolvedRepoPath,
      reference: reference.fullName,
      referenceKind: reference.kind,
      mode: strategy,
      ...(autoStash ? { autoStash: true } : {}),
    });
    notifyOperationChanged(resolvedRepoPath, `pull-${strategy}-completed`, autoStash);
    if (result?.stashRestore) {
      return {
        status: "conflicts",
        conflictedPaths: result.stashRestore.conflictedPaths,
        stashRestore: { stashReference: result.stashRestore.stashReference },
      };
    }
    return { status: "clean", warnings: result?.warnings ?? [] };
  } catch (error) {
    notifyOperationChanged(resolvedRepoPath, `pull-${strategy}-rejected`, autoStash);
    const state = await getOperationState(resolvedRepoPath).catch(() => null);
    if (state?.kind === strategy) {
      return state.conflictedPaths.length
        ? {
            status: "conflicts",
            conflictedPaths: state.conflictedPaths,
            ...(autoStash && preflight?.blockingPaths.length
              ? { deferredAutoStash: true }
              : {}),
          }
        : { status: "stopped" };
    }
    return { status: "error", message: errorMessage(error) };
  }
};

const resolveOperation = async (
  repoPath: string,
  action: "git_operation_continue" | "git_operation_abort" | "git_operation_skip",
): Promise<OperationResolution> => {
  const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
  try {
    await tauriInvoke(action, { repoPath: resolvedRepoPath });
    notifyOperationChanged(resolvedRepoPath, "operation-resolved");
    return { ok: true, message: "Git operation finished" };
  } catch (error) {
    // Even a rejected continue can change repository state, so refresh anyway.
    notifyOperationChanged(resolvedRepoPath, "operation-resolution-rejected");
    return { ok: false, message: errorMessage(error) };
  }
};

export const continueOperation = (repoPath: string) =>
  resolveOperation(repoPath, "git_operation_continue");

export const abortOperation = (repoPath: string) =>
  resolveOperation(repoPath, "git_operation_abort");

export const skipOperationStep = (repoPath: string) =>
  resolveOperation(repoPath, "git_operation_skip");
