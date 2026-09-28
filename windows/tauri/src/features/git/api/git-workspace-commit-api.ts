import { invoke } from "@/platform/tauri-core";
import { emitGitChanged } from "../events/git-events";
import type {
  WorkspaceCommitPreparation,
  WorkspaceCommitRequest,
  WorkspaceCommitSession,
} from "../types/git-workspace-commit.types";

export const prepareWorkspaceCommit = (request: WorkspaceCommitRequest, operationId: string) =>
  invoke<WorkspaceCommitPreparation>(
    "git.workspaceCommitPrepare",
    { ...request, operationId },
    { gitExecutionSource: "user" },
  );

export async function stepWorkspaceCommit(session: WorkspaceCommitSession, operationId: string) {
  try {
    return await invoke<WorkspaceCommitSession>(
      "git.workspaceCommitStep",
      { session, operationId },
      { gitExecutionSource: "user" },
    );
  } finally {
    for (const { root } of session.plan.repositories) {
      emitGitChanged({
        repoPath: root,
        scopes: ["working-tree", "history", "refs"],
        source: "workspace-commit",
      });
    }
  }
}

export const cancelWorkspaceCommit = (operationId: string) =>
  invoke<void>("core_cancel", { operationId });
