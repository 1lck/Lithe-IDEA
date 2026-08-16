import { invoke as tauriInvoke } from "@/platform/tauri-core";
import { emitGitChanged } from "../events/git-events";
import { resolveRepositoryPathOrThrow } from "./git-repo-api";
import type { GitOperationState } from "../types/git.types";

type IntegrationOperation = "merge" | "rebase";

interface IntegrationPreflightResult {
  blockingPaths: string[];
  blocksEntirely: boolean;
}

export type IntegrationOutcome =
  | { status: "clean" }
  | { status: "conflicts"; conflictedPaths: string[] }
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

const notifyOperationChanged = (repoPath: string, source: string) => {
  emitGitChanged({
    repoPath,
    scopes: ["working-tree", "history", "refs"],
    source,
  });
};

export const getOperationState = async (
  repoPath: string,
): Promise<GitOperationState | null> => {
  try {
    const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
    return await tauriInvoke<GitOperationState | null>("git_operation_state", {
      repoPath: resolvedRepoPath,
    });
  } catch {
    return null;
  }
};

export const getConflictMarkerPaths = async (repoPath: string): Promise<string[]> => {
  try {
    const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
    const result = await tauriInvoke<{ paths: string[] }>("git_conflict_markers", {
      repoPath: resolvedRepoPath,
    });
    return result.paths;
  } catch {
    return [];
  }
};

const runIntegration = async (
  repoPath: string,
  branchName: string,
  operation: IntegrationOperation,
): Promise<IntegrationOutcome> => {
  const command = operation === "merge" ? "git_merge" : "git_rebase";
  try {
    await tauriInvoke(command, { repoPath, branchName });
    notifyOperationChanged(repoPath, `${operation}-completed`);
    return { status: "clean" };
  } catch (error) {
    // A conflict stop exits non-zero like a real failure; the authoritative
    // distinction is whether Git left an operation state behind.
    const state = await getOperationState(repoPath);
    if (state && state.kind === operation && state.conflictedPaths.length > 0) {
      notifyOperationChanged(repoPath, `${operation}-conflicts`);
      return { status: "conflicts", conflictedPaths: state.conflictedPaths };
    }
    return { status: "error", message: errorMessage(error) };
  }
};

const startIntegration = async (
  repoPath: string,
  branchName: string,
  operation: IntegrationOperation,
): Promise<IntegrationOutcome> => {
  const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);

  let preflight: IntegrationPreflightResult | null = null;
  try {
    preflight = await tauriInvoke<IntegrationPreflightResult>(
      "git_integration_preflight",
      { repoPath: resolvedRepoPath, branchName, operation },
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

  return runIntegration(resolvedRepoPath, branchName, operation);
};

export const mergeBranch = (repoPath: string, branchName: string) =>
  startIntegration(repoPath, branchName, "merge");

export const rebaseOntoBranch = (repoPath: string, branchName: string) =>
  startIntegration(repoPath, branchName, "rebase");

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
