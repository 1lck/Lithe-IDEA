import { invoke as tauriInvoke } from "@/platform/tauri-core";
import { emitGitChanged } from "../events/git-events";
import type { GitDiff } from "../types/git.types";
import { commitDiffChangeID } from "../utils/commit-diff-blocks";
import { planIndependentCommitDiff } from "../utils/independent-commit-diff";
import { monacoDiffRows } from "../utils/monaco-diff-rows";

/** One Core-planned block. Hosts address it by `id`; Core owns its patches. */
export interface CommitDiffBlock {
  /** `line-<index>` into the compared file's unified lines. */
  id: string;
  checked: boolean;
  indeterminate: boolean;
  canToggle: boolean;
  canRollback: boolean;
  /** New and deleted files toggle as a whole through ordinary staging. */
  wholeFile?: boolean;
  /** Unfolded model indices; presentation maps the stable row ID after folding. */
  leftStart: number;
  rightStart: number;
}

/** Core's block as sent over the wire, before display positions are attached. */
type PlannedBlock = Omit<CommitDiffBlock, "leftStart" | "rightStart">;

/** One file a commit review compares, as Core resolves it. */
export interface CommitDiffBlockTarget {
  repoPath: string;
  /** Repository-relative path. */
  filePath: string;
  originalPath?: string;
  /** Review HEAD -> index instead of HEAD -> worktree. */
  staged?: boolean;
}

/** Core's commit-review read: both comparisons, their blocks and the snapshot token. */
export interface CommitDiffBlockPlan {
  /** HEAD -> worktree (or HEAD -> index for an index review), complete-file. */
  diff: GitDiff;
  /** HEAD -> index, complete-file; no lines when the index matches HEAD. */
  staged: GitDiff;
  blocks: CommitDiffBlock[];
  /** Identifies the read; a write planned from another read is refused. */
  token: string;
}

export type CommitDiffBlockAction = "include" | "exclude" | "rollback";
export type CommitDiffBlockWriteResult = "applied" | "stale" | "unsafe" | "failed";

const payload = (target: CommitDiffBlockTarget) => ({
  root: target.repoPath,
  path: target.filePath,
  ...(target.originalPath ? { originalPath: target.originalPath } : {}),
  ...(target.staged ? { staged: true } : {}),
});

const errorMessage = (error: unknown) => (error instanceof Error ? error.message : String(error));

/** Reads one commit review. Core reads Git, plans blocks and owns every patch. */
export async function planCommitDiffBlocks(target: CommitDiffBlockTarget): Promise<CommitDiffBlockPlan> {
  const plan = await tauriInvoke<Omit<CommitDiffBlockPlan, "blocks"> & { blocks: PlannedBlock[] }>(
    "git.planDiffBlocks", payload(target));
  // Every line of the file is present as context, so reviews fold locally.
  const diff = { ...plan.diff, is_full_context: true };
  // Locate each Core block in the display rows; the block's patches stay in Core.
  const display = planIndependentCommitDiff(monacoDiffRows(diff, { hideHunkHeaders: true }), false, new Set());
  const positions = new Map(display.changes.map(change =>
    [commitDiffChangeID(display, change), change] as const));
  const blocks = plan.blocks.flatMap((block): CommitDiffBlock[] => {
    const change = positions.get(block.id);
    return change ? [{ ...block, leftStart: change.leftStart, rightStart: change.rightStart }] : [];
  });
  return { ...plan, diff, staged: { ...plan.staged, is_full_context: true }, blocks };
}

/**
 * Applies one planned block action. Core re-reads the file under its write
 * lease and refuses the write when the token no longer describes it.
 */
export async function applyCommitDiffBlock(
  target: CommitDiffBlockTarget,
  blockId: string,
  action: CommitDiffBlockAction,
  token: string,
): Promise<CommitDiffBlockWriteResult> {
  try {
    await tauriInvoke("git.applyDiffBlock", { ...payload(target), blockId, action, token });
  } catch (error) {
    const message = errorMessage(error);
    if (message.includes("GIT_DIFF_BLOCK_STALE")) return "stale";
    if (message.includes("GIT_HUNK_ROLLBACK_UNSAFE")) return "unsafe";
    console.error("Failed to write Git diff block:", error);
    return "failed";
  }
  emitGitChanged({
    repoPath: target.repoPath,
    filePath: target.filePath,
    scopes: ["working-tree"],
    source: action === "rollback" ? "discard-hunk" : action === "include" ? "stage-hunk" : "unstage-hunk",
  });
  return "applied";
}

/** One editor gutter change, in Monaco's one-based, end-exclusive ranges. */
export interface GitGutterChangeRequest {
  repoPath: string;
  filePath: string;
  originalStart: number;
  originalEnd: number;
  modifiedStart: number;
  modifiedEnd: number;
  originalLines: readonly string[];
  modifiedLines: readonly string[];
}

/**
 * Stages exactly one editor change. Core confirms the index and the saved file
 * still show the compared lines and stages them with their original bytes.
 */
export async function stageGitGutterChangeInCore(
  change: GitGutterChangeRequest,
): Promise<"applied" | "stale" | "failed"> {
  const { repoPath, filePath, ...range } = change;
  try {
    await tauriInvoke("git.stageGutterChange", { root: repoPath, path: filePath, ...range });
  } catch (error) {
    if (errorMessage(error).includes("GIT_GUTTER_CHANGE_STALE")) return "stale";
    console.error("Failed to stage Git gutter change:", error);
    return "failed";
  }
  emitGitChanged({ repoPath, filePath, scopes: ["working-tree"], source: "stage-hunk" });
  return "applied";
}
