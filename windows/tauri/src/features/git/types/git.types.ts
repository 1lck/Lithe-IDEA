export interface GitFile {
  path: string;
  originalPath?: string;
  status: "modified" | "added" | "deleted" | "untracked" | "renamed";
  staged: boolean;
  /** Raw porcelain XY status retained for whole-path commit review semantics. */
  rawStatus?: string;
  /** Whether the worktree differs from the index for this path. */
  worktree?: boolean;
}

export interface GitStatus {
  branch: string;
  ahead: number;
  behind: number;
  files: GitFile[];
}

export interface GitCommit {
  hash: string;
  shortHash: string;
  parentHashes: string[];
  message: string;
  description?: string;
  author: string;
  email?: string;
  date: string;
  decorations: string;
}

export type GitReferenceKind = "local" | "remote" | "tag";

export interface GitReference {
  fullName: string;
  shortName: string;
  kind: GitReferenceKind;
  peelsToCommit: boolean;
  isCurrent: boolean;
  upstreamShortName?: string;
  ahead?: number;
  behind?: number;
}

export interface GitHistorySnapshot {
  references: GitReference[];
  recentReferences: GitReference[];
  commits: GitCommit[];
  hasMore: boolean;
}

export type GitPushTagScope = "none" | "all" | "reachable";

export interface GitPushExpectation {
  localBranch: string;
  localHead: string;
  remote: string;
  remoteBranch: string;
  remoteTrackingOid: string | null;
  tags: GitPushTagSnapshot[];
}

export interface GitPushTagSnapshot {
  fullName: string;
  objectId: string;
}

export interface GitOperationWarning {
  code: string;
  message: string;
  details?: string;
}

export interface GitPushPreview extends GitPushExpectation {
  upstream: string | null;
  commits: GitCommit[];
  hasMore: boolean;
}

export interface GitReferenceSnapshot {
  references: GitReference[];
  recentReferences: GitReference[];
}

export interface GitHistoryPage {
  commits: GitCommit[];
  nextCursor?: string;
  hasMore: boolean;
}

export interface GitCommitFile {
  status: string;
  path: string;
}

export interface GitDiffLine {
  line_type: "added" | "removed" | "context" | "header";
  content: string;
  old_line_number?: number;
  new_line_number?: number;
}

export interface GitDiffSplitRow {
  kind: "context" | "changed" | "addition" | "removal";
  old_line_number?: number;
  new_line_number?: number;
  old_content?: string;
  new_content?: string;
  is_invisible_change?: boolean;
}

export interface GitDiff {
  file_path: string;
  old_path?: string;
  new_path?: string;
  is_new: boolean;
  is_deleted: boolean;
  is_renamed: boolean;
  lines: GitDiffLine[];
  is_binary?: boolean;
  is_image?: boolean;
  old_blob_base64?: string;
  new_blob_base64?: string;
  raw_patch?: string;
  additions?: number;
  deletions?: number;
  is_truncated?: boolean;
  split_hunks?: GitDiffSplitRow[][];
}

export interface GitDiffStat {
  file_path: string;
  staged: boolean;
  additions: number;
  deletions: number;
}

export interface GitHunk {
  file_path: string;
  lines: GitDiffLine[];
}

export interface GitRemote {
  name: string;
  url: string;
}

/** The current branch's relationship with its configured upstream. */
export interface GitPullPreflight {
  upstream: string | null;
  ahead: number;
  behind: number;
  diverged: boolean;
  hasLocalChanges: boolean;
}

/** A pull policy accepted by the shared Rust Core. */
export type PullStrategy = "ffOnly" | "merge" | "rebase";

export type GitPullResult =
  | { status: "pulled"; strategy: PullStrategy }
  | { status: "cancelled" }
  | {
      status: "blocked";
      reason: "no-upstream" | "up-to-date" | "dirty" | "state-changed";
    }
  | {
      status: "failed";
      stage: "fetch" | "preflight" | "pull";
      error?: string;
    }
  | { status: "conflict"; operation: GitOperationState }
  | { status: "duplicate" };

export interface GitStash {
  index: number;
  message: string;
  date: string;
}

export interface GitTag {
  name: string;
  commit: string;
  message?: string;
  date: string;
  is_annotated: boolean;
}

export interface GitWorktree {
  path: string;
  branch?: string;
  head: string;
  is_bare: boolean;
  is_detached: boolean;
  locked_reason?: string;
  prunable_reason?: string;
  is_current: boolean;
}

export interface GitBlame {
  file_path: string;
  lines: GitBlameLine[];
}

export interface GitBlameLine {
  line_number: number;
  total_lines: number;
  commit_hash: string;
  is_uncommitted: boolean;
  author: string;
  email: string;
  time: number;
  commit: string;
}

export type GitOperationKind = "merge" | "rebase" | "cherryPick" | "revert";

/**
 * An in-progress merge/rebase/cherry-pick/revert detected from the repository's
 * Git marker files, so operations started outside the app are reported too.
 */
export interface GitOperationState {
  kind: GitOperationKind;
  reference: string | null;
  step: number | null;
  total: number | null;
  conflictedPaths: string[];
}
