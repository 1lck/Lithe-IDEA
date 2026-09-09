import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { useRepositoryStore } from "../stores/git-repository.store";

export interface GitRebaseDialogRequest {
  id: string;
  repoPath: string;
  workspaceId: string;
  selectedRepository: string | null;
  revision?: string;
}
let host: ((request: GitRebaseDialogRequest) => void) | null = null;
export function showGitRebaseDialog(repoPath: string, revision?: string): void {
  host?.({
    id: crypto.randomUUID(),
    repoPath,
    revision,
    workspaceId: workspaceRuntimeRegistry.getActiveWorkspaceId(),
    selectedRepository: useRepositoryStore.getState().activeRepoPath,
  });
}
export function attachGitRebaseDialogHost(
  next: (request: GitRebaseDialogRequest) => void,
): () => void {
  host = next;
  return () => {
    if (host === next) host = null;
  };
}
