import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { useRepositoryStore } from "../stores/git-repository.store";
import type { GitReference } from "../types/git.types";

export interface GitWorktreeDialogRequest {
  id: string;
  repoPath: string;
  workspaceId: string;
  selectedRepository: string | null;
  reference?: GitReference;
  destination?: string;
  resolve: (changed: boolean) => void;
}

let enqueueRequest: ((request: GitWorktreeDialogRequest) => void) | null = null;

export function showGitWorktreeDialog(
  repoPath: string,
  options: { reference?: GitReference; destination?: string } = {},
): Promise<boolean> {
  return new Promise((resolve) => {
    if (!enqueueRequest) {
      resolve(false);
      return;
    }
    enqueueRequest({
      ...options,
      id: crypto.randomUUID(),
      repoPath,
      workspaceId: workspaceRuntimeRegistry.getActiveWorkspaceId(),
      selectedRepository: useRepositoryStore.getState().activeRepoPath,
      resolve,
    });
  });
}

export function attachGitWorktreeDialogHost(
  enqueue: (request: GitWorktreeDialogRequest) => void,
): () => void {
  enqueueRequest = enqueue;
  return () => {
    if (enqueueRequest === enqueue) enqueueRequest = null;
  };
}
