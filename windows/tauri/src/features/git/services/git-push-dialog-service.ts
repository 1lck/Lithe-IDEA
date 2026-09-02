import type { GitReference } from "../types/git.types";

export interface GitPushDialogRequest {
  id: number;
  repoPath: string;
  reference?: GitReference | string;
  resolve: (pushed: boolean) => void;
}

type GitPushDialogEnqueue = (request: GitPushDialogRequest) => void;

let nextRequestId = 1;
let enqueueRequest: GitPushDialogEnqueue | null = null;
const pendingRequests: GitPushDialogRequest[] = [];

export function showGitPushDialog(
  repoPath: string,
  reference?: GitReference | string,
): Promise<boolean> {
  return new Promise((resolve) => {
    const request = { id: nextRequestId++, repoPath, reference, resolve };
    if (enqueueRequest) enqueueRequest(request);
    else pendingRequests.push(request);
  });
}

export function attachGitPushDialogHost(enqueue: GitPushDialogEnqueue): () => void {
  enqueueRequest = enqueue;
  for (const request of pendingRequests.splice(0)) enqueue(request);
  return () => {
    if (enqueueRequest === enqueue) enqueueRequest = null;
  };
}
