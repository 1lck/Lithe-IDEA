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
export interface WorkspaceCommitPathScope {
  include: boolean;
  paths: Record<string, string[]>;
}
export interface WorkspaceCommitPlan {
  pathScope?: WorkspaceCommitPathScope;
  repositories: WorkspaceRepositoryBinding[];
  message: string;
  amend: boolean;
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
export interface WorkspaceCommitRequest {
  pathScope?: WorkspaceCommitPathScope;
  repositories: WorkspaceRepositoryBinding[];
  message: string;
  amend: boolean;
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
