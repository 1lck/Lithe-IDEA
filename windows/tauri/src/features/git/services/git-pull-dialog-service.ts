/** User-visible outcome of one Pull dialog session, used by callers to react after the fact. */
export type GitPullDialogStatus = "pulled" | "cancelled" | "blocked" | "conflict" | "failed";

export interface GitPullDialogResult {
  status: GitPullDialogStatus;
}

export interface GitPullDialogRequest {
  id: number;
  repoPath: string;
  /** Caller-owned refresh run after the pull touches the repository. */
  refresh?: () => Promise<void>;
  resolve: (result: GitPullDialogResult) => void;
}

type GitPullDialogEnqueue = (request: GitPullDialogRequest) => void;

let nextRequestId = 1;
let enqueueRequest: GitPullDialogEnqueue | null = null;
const pendingRequests: GitPullDialogRequest[] = [];

/**
 * Opens the single Pull dialog for a repository. The returned promise resolves
 * once the user confirms a completed pull or cancels the dialog.
 */
export function showGitPullDialog(
  repoPath: string,
  options: { refresh?: () => Promise<void> } = {},
): Promise<GitPullDialogResult> {
  return new Promise((resolve) => {
    const request: GitPullDialogRequest = {
      id: nextRequestId++,
      repoPath,
      refresh: options.refresh,
      resolve,
    };
    if (enqueueRequest) enqueueRequest(request);
    else pendingRequests.push(request);
  });
}

export function attachGitPullDialogHost(enqueue: GitPullDialogEnqueue): () => void {
  enqueueRequest = enqueue;
  for (const request of pendingRequests.splice(0)) enqueue(request);
  return () => {
    if (enqueueRequest === enqueue) enqueueRequest = null;
  };
}
