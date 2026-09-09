import type {
  GitHistoryRewriteCommit,
  GitHistoryRewriteExpectation,
  GitHistoryRewriteResult,
} from "./git-history-rewrite.types";

export type GitRebaseAction = "pick" | "reword" | "edit" | "squash" | "fixup" | "drop";
export interface GitRebaseStep {
  hash: string;
  action: GitRebaseAction;
  message?: string;
}
export interface GitRebasePreview {
  allowed: boolean;
  blockers: Array<{ code: string; message: string }>;
  branch: string | null;
  head: string | null;
  base: string | null;
  commits: GitHistoryRewriteCommit[];
  expectedState:
    | (Omit<GitHistoryRewriteExpectation, "operation"> & { operation: "interactiveRebase" })
    | null;
}
export interface GitRebaseSession {
  sessionId: string;
  status:
    | "starting"
    | "conflict"
    | "edit"
    | "paused"
    | "completed"
    | "aborted"
    | "failed"
    | "interrupted";
  branch: string;
  originalHead: string;
  head: string | null;
  recoveryReference: string;
  steps: GitRebaseStep[];
  completedSteps: number;
  currentCommit: string | null;
  currentMessage: string | null;
  conflictedPaths: string[];
  canContinue: boolean;
  canSkip: boolean;
  canAbort: boolean;
}
export interface GitRebaseResult {
  command: GitHistoryRewriteResult;
  session: GitRebaseSession;
}
