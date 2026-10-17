import { invoke as tauriInvoke } from "@/platform/tauri-core";
import type { GitLineHistory } from "../types/git.types";
import { isNotGitRepositoryError, resolveRepositoryForFile } from "./git-repo-api";

export interface GitLineHistoryQuery {
  rootPath: string;
  filePath: string;
  /** Editor buffer content at query time; the range addresses this snapshot. */
  content: string;
  startLine: number;
  endLine: number;
  limit?: number;
  operationId: string;
  /** Abort check that also covers repository discovery, before the core
   * operation id exists for cancelCoreOperation. */
  isCancelled?: () => boolean;
}

export interface ResolvedGitLineHistory {
  history: GitLineHistory;
  repoPath: string;
  filePath: string;
}

export const getGitLineHistory = async (
  query: GitLineHistoryQuery,
): Promise<ResolvedGitLineHistory | null> => {
  try {
    const resolved = await resolveRepositoryForFile(query.rootPath, query.filePath);
    if (!resolved) {
      return null;
    }
    if (query.isCancelled?.()) {
      return null;
    }

    // The dotted shared-core command rides the central platform dispatcher
    // directly; no compatibility Tauri command exists for line history.
    const history = await tauriInvoke<GitLineHistory>("git.lineHistory", {
      root: resolved.repoPath,
      path: resolved.filePath,
      content: query.content,
      startLine: query.startLine,
      endLine: query.endLine,
      limit: query.limit,
      operationId: query.operationId,
    });
    return {
      history,
      repoPath: resolved.repoPath,
      filePath: resolved.filePath,
    };
  } catch (error) {
    if (!isNotGitRepositoryError(error)) {
      console.error("Failed to get git line history:", error);
    }
    return null;
  }
};
