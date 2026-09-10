import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { useRepositoryStore } from "../stores/git-repository.store";
import type { GitCommit } from "../types/git.types";

export interface GitPatchDialogOptions {
  mode: "export" | "apply";
  paths?: string[];
  commits?: GitCommit[];
}

export interface GitPatchDialogRequest extends GitPatchDialogOptions {
  id: string;
  repoPath: string;
  workspaceId: string;
  selectedRepository: string | null;
  resolve: (completed: boolean) => void;
}

let enqueueRequest: ((request: GitPatchDialogRequest) => void) | null = null;

export function showGitPatchDialog(
  repoPath: string,
  options: GitPatchDialogOptions,
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

export function attachGitPatchDialogHost(
  enqueue: (request: GitPatchDialogRequest) => void,
): () => void {
  enqueueRequest = enqueue;
  return () => {
    if (enqueueRequest === enqueue) enqueueRequest = null;
  };
}
