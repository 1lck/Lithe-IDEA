import type { GitDiff, GitFile } from "../types/git.types";
import type { CommitDiffBlock, CommitDiffBlockAction, CommitDiffFileAction, CommitDiffBlockWriteResult } from "../api/git-diff-block-api";

/** One Core read: both comparisons, the planned blocks and the token that
 * identifies the read. Core refuses any write planned from another read. */
export interface CommitDiffSnapshot {
  diff: GitDiff;
  staged: GitDiff;
  file: GitFile;
  blocks: CommitDiffBlock[];
  token: string;
}
export interface CommitDiffReviewState {
  snapshot: CommitDiffSnapshot | null;
  blocks: CommitDiffBlock[];
  busy: boolean;
  error?: "read" | "write" | "stale" | "unsafe";
}

/** Display index-only changes without using them as a working-tree write base.
 * File inclusion is status-owned even when no precise block can be produced. */
export function commitDiffPresentation(snapshot: CommitDiffSnapshot, stagedView: boolean) {
  const hasChanges = (diff: GitDiff) => diff.is_binary || diff.is_image || diff.is_renamed
    || diff.is_new || diff.is_deleted || diff.lines.some(line => line.line_type === "added" || line.line_type === "removed");
  const showingIndex = stagedView || (!hasChanges(snapshot.diff) && snapshot.file.staged && hasChanges(snapshot.staged));
  return {
    diff: showingIndex ? snapshot.staged : snapshot.diff,
    staged: showingIndex,
    included: snapshot.file.staged,
    indeterminate: !stagedView && snapshot.file.staged && snapshot.file.worktree === true,
  };
}
interface Dependencies {
  read: () => Promise<CommitDiffSnapshot | null>;
  /** Core re-plans under its write lock and refuses a stale token. */
  writeBlock: (snapshot: CommitDiffSnapshot, blockId: string | null,
    action: CommitDiffBlockAction | CommitDiffFileAction)
    => Promise<CommitDiffBlockWriteResult>;

  changed: (state: CommitDiffReviewState) => void;
  beginWrite?: () => () => void;
  canWrite?: () => boolean;
  writeAvailable?: () => boolean;
}

/** One live file review owns reads and block writes, including direct rollback.
 * Git index state is the only source of selection. Core validates the snapshot
 * token under its write lock; stale controls never apply an old snapshot. */
export function createCommitDiffReview(dependencies: Dependencies) {
  let state: CommitDiffReviewState = { snapshot: null, blocks: [], busy: false };
  let closed = false, generation = 0, dirty = false;
  let refreshing: Promise<void> | null = null;
  const publish = (next: CommitDiffReviewState) => {
    if (closed) return;
    state = next;
    dependencies.changed(state);
  };
  const accept = (snapshot: CommitDiffSnapshot | null, error?: CommitDiffReviewState["error"]) => {
    publish({ snapshot, blocks: snapshot?.blocks ?? [],
      busy: state.busy, ...(error ? { error } : {}) });
  };
  async function refresh(): Promise<void> {
    if (closed) return;
    dirty = true;
    generation++;
    if (state.busy) return;
    if (refreshing) return refreshing;
    refreshing = (async () => {
      while (dirty && !closed && !state.busy) {
        dirty = false;
        const request = generation;
        try {
          const snapshot = await dependencies.read();
          if (!closed && request === generation) accept(snapshot);
        } catch {
          if (!closed && request === generation) publish({ ...state, error: "read" });
        }
      }
    })().finally(() => { refreshing = null; });
    return refreshing;
  }
  async function apply(id: string | null, action: "include" | "exclude" | "rollback") {
    const snapshot = state.snapshot;
    const block = state.blocks.find(block => block.id === id);
    if (closed || state.busy || refreshing || !snapshot || dependencies.canWrite?.() === false
      || dependencies.writeAvailable?.() === false) return "ignored";
    if (id !== null && (!block || (action === "rollback" ? !block.canRollback : !block.canToggle))) return "ignored";
    if (id === null && action === "rollback") return "ignored";
    const endWrite = dependencies.beginWrite?.();
    publish({ ...state, busy: true, error: undefined });
    try {
      if (closed || dependencies.canWrite?.() === false) return "ignored";
      // Whole-file inclusion carries the same token as a block write.
      const outcome = await dependencies.writeBlock(snapshot,
        id === null || block?.wholeFile ? null : id,
        id === null || block?.wholeFile ? (action === "include" ? "includeFile" : "excludeFile") : action);
      if (outcome === "stale") {
        // The file moved after the user saw it: show what is there now.
        publish({ ...state, error: "stale" });
        return "stale";
      }
      if (outcome === "unsafe") {
        publish({ ...state, error: "unsafe" });
        return "failed";
      }
      const result = outcome === "applied";
      if (!closed && !result) publish({ ...state, error: "write" });
      return result ? "applied" : "failed";
    } catch {
      if (!closed) publish({ ...state, error: "write" });
      return "failed";
    } finally {
      try {
        if (!closed) {
          const error = state.error;
          publish({ ...state, busy: false });
          await refresh();
          if (error && !closed) publish({ ...state, error });
        }
      } finally {
        endWrite?.();
      }
    }
  }
  return {
    refresh,
    apply,
    // Model-level view of the newest snapshot: publish() updates it before
    // any React rerender, so confirmation identity checks read this instead
    // of a render-phase ref.
    currentState: () => state,
    dispose() { closed = true; generation++; dirty = false; },
  };
}
