/** Wire DTOs owned by Rust git::workspace_commit; clients return continuations unchanged. */
import type { GitPushTargetChoice } from "./git.types";

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
/** A divergent destination the user confirmed for one repository. */
export interface WorkspaceCommitPushTarget {
  choice: GitPushTargetChoice;
  remote: string;
  /** The exact remote branch the user was shown; Core rejects a changed destination. */
  remoteBranch: string;
}
/** A push whose branch tracks a differently named remote branch and needs an answer. */
export interface WorkspaceCommitPushTargetQuestion {
  repositoryId: string;
  localBranch: string;
  remote: string;
  /** Upstream short name such as `origin/release`. */
  upstream: string;
  /** The upstream's branch name on `remote`; may itself contain slashes. */
  upstreamBranch: string;
}
export interface WorkspaceCommitPlan {
  pathScope?: WorkspaceCommitPathScope;
  repositories: WorkspaceRepositoryBinding[];
  message: string;
  amend: boolean;
  push: boolean;
  /** Confirmed destinations by repository ID; absent when no branch needed one. */
  pushTargets?: Record<string, WorkspaceCommitPushTarget>;
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
  /** Answers to earlier questions by repository ID; a retry restores them in Core. */
  pushTargets?: Record<string, WorkspaceCommitPushTarget>;
  includeParentReferences: boolean;
  previous?: WorkspaceCommitSession;
  reviewed?: WorkspaceCommitPlan;
}
export interface WorkspaceCommitPreparation {
  session: WorkspaceCommitSession;
  reviewChanged: boolean;
  requiresConfirmation: boolean;
  /**
   * Pushes still waiting for a destination choice. While non-empty the session must
   * not be stepped: Core refuses to commit rather than strand a commit it cannot push.
   */
  pushTargetQuestions?: WorkspaceCommitPushTargetQuestion[];
}
