import { invoke } from "@/platform/tauri-core";
import { emitGitChanged } from "../events/git-events";
import type {
  GitHistoryRewriteOperation,
  GitHistoryRewritePreview,
  GitHistoryRewriteResult,
} from "../types/git-history-rewrite.types";
import { resolveRepositoryPathOrThrow } from "./git-repo-api";

export async function getGitHistoryRewritePreview(
  repoPath: string,
  operation: GitHistoryRewriteOperation,
  revisions: string[],
  operationId: string,
): Promise<GitHistoryRewritePreview> {
  const root = await resolveRepositoryPathOrThrow(repoPath);
  return invoke("git.historyRewritePreview", { root, operation, revisions, operationId });
}

export async function executeGitHistoryRewrite(
  repoPath: string,
  preview: GitHistoryRewritePreview,
  message?: string,
): Promise<GitHistoryRewriteResult> {
  if (!preview.allowed || !preview.expectedState) {
    throw new Error(preview.blockers.map((blocker) => blocker.message).join("\n"));
  }
  const root = await resolveRepositoryPathOrThrow(repoPath);
  const { operation, revisions } = preview.expectedState;
  try {
    // Return the complete outcome even after a partial mutation. The dialog must
    // retain recovery references and warnings when Git reports an error.
    return await invoke("git.write", {
      root,
      operation,
      ...(operation === "squashCommits" ? { revisions } : { revision: revisions[0] }),
      ...(message === undefined ? {} : { message }),
      expectedState: preview.expectedState,
    });
  } finally {
    emitGitChanged({
      repoPath: root,
      scopes: ["working-tree", "history", "refs"],
      source: "history-rewrite",
    });
  }
}
