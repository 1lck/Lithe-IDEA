import equal from "fast-deep-equal";
import type { GitDiff, GitFile, GitHunk } from "../types/git.types";
import type { CommitDiffBlock } from "../utils/commit-diff-blocks";
import { planCommitDiffBlocks } from "../utils/commit-diff-blocks";

export interface CommitDiffSnapshot {
  diff: GitDiff;
  staged: GitDiff;
  file: GitFile;
}
export interface CommitDiffReviewState {
  snapshot: CommitDiffSnapshot | null;
  blocks: CommitDiffBlock[];
  busy: boolean;
  error?: "read" | "write" | "stale";
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
  stage: (hunk: GitHunk) => Promise<boolean>;
  unstage: (hunk: GitHunk) => Promise<boolean>;
  rollback: (hunk: GitHunk) => Promise<boolean>;
  includeFile: (included: boolean) => Promise<boolean>;
  changed: (state: CommitDiffReviewState) => void;
  beginWrite?: () => () => void;
  canWrite?: () => boolean;
  writeAvailable?: () => boolean;
}

/** One live file review owns reads and block writes, including direct rollback.
 * Git index state is the only source of selection. Re-read before writing;
 * stale controls must never apply an old snapshot. */
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
    publish({ snapshot, blocks: snapshot ? planCommitDiffBlocks(snapshot.diff, snapshot.staged) ?? [] : [],
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
    const hunk = action === "include" ? block?.stage : action === "exclude" ? block?.unstage : block?.rollback;
    if (id !== null && !hunk && !block?.wholeFile) return "ignored";
    const endWrite = dependencies.beginWrite?.();
    publish({ ...state, busy: true, error: undefined });
    try {
      if (closed || dependencies.canWrite?.() === false) return "ignored";
      const request = generation;
      const fresh = await dependencies.read();
      if (closed || dependencies.canWrite?.() === false) return "ignored";
      if (request !== generation || !equal(fresh, snapshot)) {
        accept(fresh, "stale");
        return "stale";
      }
      const result = id === null || block?.wholeFile
        ? await dependencies.includeFile(action === "include")
        : await (action === "include" ? dependencies.stage : action === "exclude"
          ? dependencies.unstage : dependencies.rollback)(hunk!);
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
  return { refresh, apply, dispose() { closed = true; generation++; dirty = false; } };
}
