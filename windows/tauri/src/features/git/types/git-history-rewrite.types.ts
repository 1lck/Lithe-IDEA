import type { GitOperationWarning } from "./git.types";

export type GitHistoryRewriteOperation =
  | "undoCommit"
  | "editCommitMessage"
  | "squashCommits"
  | "deleteCommit";

export interface GitHistoryRewriteCommit {
  hash: string;
  parents: string[];
  /** Complete message, including its subject and body. */
  message: string;
}

export interface GitHistoryRewriteExpectation {
  branch: string;
  head: string;
  stateToken: string;
  operation: GitHistoryRewriteOperation;
  revisions: string[];
}

export interface GitHistoryRewritePreview {
  operation: GitHistoryRewriteOperation;
  allowed: boolean;
  blockers: Array<{ code: string; message: string }>;
  branch: string | null;
  head: string | null;
  /** Core orders both lists from oldest to newest, independently of Log filtering. */
  selectedCommits: GitHistoryRewriteCommit[];
  affectedCommits: GitHistoryRewriteCommit[];
  suggestedMessage: string;
  expectedState: GitHistoryRewriteExpectation | null;
}

export interface GitHistoryRewriteResult {
  output?: string;
  exitCode?: number;
  operationError?: { code: string; message: string; details?: string } | null;
  warnings?: GitOperationWarning[];
  historyRewrite?: {
    operation: GitHistoryRewriteOperation;
    branch: string;
    originalHead: string;
    newHead: string | null;
    recoveryReference: string;
    mutationApplied: boolean;
    outcomeKnown: boolean;
    worktreeRefresh: "notNeeded" | "ready" | "failed";
  };
}
