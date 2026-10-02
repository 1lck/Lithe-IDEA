/** Wire DTOs owned by Rust git::workspace_commit; clients return continuations unchanged. */
export interface WorkspaceRepositoryBinding {
  id: string;
  root: string;
}
export interface WorkspaceCommitState {
  head: string | null;
  branch: string | null;
  indexEntries: string;
  gitlinks: { path: string; revision: string }[];
  stagedPaths: string[];
  conflictedPaths: string[];
}
export interface WorkspaceCommitRelation {
  parent: string;
  child: string;
  path: string;
}
export interface WorkspaceCommitPlan {
  repositories: WorkspaceRepositoryBinding[];
  message: string;
  amend: boolean;
  /** The one repository an amend rewrites; Core carries it through retries unchanged. */
  amendRepositoryId?: string;
  push: boolean;
  includeParentReferences: boolean;
  isRetry: boolean;
  orderedIds: string[];
  propagatedRelations: WorkspaceCommitRelation[];
  dependencyRelations: WorkspaceCommitRelation[];
  states: Record<string, WorkspaceCommitState>;
  committedIds: string[];
  pendingPushIds: string[];
}
export interface WorkspaceCommitSession {
  plan: WorkspaceCommitPlan;
  states: Record<string, WorkspaceCommitState>;
  results: Record<string, { committed: boolean; pushed: boolean; status: string; detail: string }>;
  blocked: string[];
  cursor: number;
  commandFailed: boolean;
  finished: boolean;
  succeeded: boolean;
  canRetry: boolean;
}
/** The repository and HEAD an amend message was loaded from; Core rejects any other target. */
export interface WorkspaceAmendTarget {
  repositoryId: string;
  expectedHead: string;
}
export interface WorkspaceCommitRequest {
  repositories: WorkspaceRepositoryBinding[];
  message: string;
  amend: boolean;
  amendTarget?: WorkspaceAmendTarget;
  push: boolean;
  includeParentReferences: boolean;
  previous?: WorkspaceCommitSession;
  reviewed?: WorkspaceCommitPlan;
}
export interface WorkspaceCommitPreparation {
  session: WorkspaceCommitSession;
  reviewChanged: boolean;
  requiresConfirmation: boolean;
}
