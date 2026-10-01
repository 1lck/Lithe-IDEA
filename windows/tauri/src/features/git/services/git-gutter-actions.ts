import { activateMainEditorPane } from "@/features/editor/stores/buffer-pane-sync";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { getWorkingTreePathDiff } from "../api/git-diff-api";
import { stageHunk } from "../api/git-status-api";
import type { GitGutterBase } from "../hooks/use-git-gutter-base";
import { gitGutterChangeHunk, type GitGutterChange } from "../utils/git-gutter-changes";
import { createSingleFileWorkingTreeDiff } from "../utils/working-tree-multi-diff";

/**
 * Stages one gutter change through the existing hunk API. The patch is built
 * against the index text the change was computed from, so Git rejects it
 * instead of staging the wrong lines if the index moved in the meantime.
 */
export function stageGitGutterChange(
  base: GitGutterBase,
  baseLines: readonly string[],
  change: GitGutterChange,
): Promise<boolean> {
  return stageHunk(base.repoPath, gitGutterChangeHunk(base.filePath, baseLines, change));
}

/**
 * Opens the same single-file working-tree Diff tab as the Changes panel
 * (HEAD to working tree, full context, per-hunk staging).
 */
export async function openGitGutterFullDiff(
  base: GitGutterBase,
  title: string,
): Promise<string | null> {
  const diff = await getWorkingTreePathDiff(base.repoPath, base.filePath, false, undefined, true);
  if (!diff || (diff.lines.length === 0 && !diff.is_image && !diff.is_binary)) return null;
  const fileKey = `unstaged:${base.filePath}`;
  const multiDiff = createSingleFileWorkingTreeDiff({
    repoPath: base.repoPath,
    fileKey,
    diff,
    title,
    target: { repoPath: base.repoPath, filePath: base.filePath, untracked: false },
  });
  activateMainEditorPane();
  return useBufferStore
    .getState()
    .actions.openBuffer("diff://working-tree/all-files", title, "", false, undefined, true, true, multiDiff);
}
