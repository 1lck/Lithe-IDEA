import { activateMainEditorPane } from "@/features/editor/stores/buffer-pane-sync";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { getWorkingTreePathDiff } from "../api/git-diff-api";
import { stageGitGutterChangeInCore } from "../api/git-diff-block-api";
import type { GitGutterBase } from "../hooks/use-git-gutter-base";
import type { GitGutterChange } from "../utils/git-gutter-changes";
import { createSingleFileWorkingTreeDiff } from "../utils/working-tree-multi-diff";

/**
 * Stages one gutter change through Core. Core confirms the index and the saved
 * file still show the compared lines, then builds the patch from original
 * bytes; the host sends only the change's ranges and lines.
 */
export async function stageGitGutterChange(
  base: GitGutterBase,
  change: GitGutterChange,
): Promise<boolean> {
  const result = await stageGitGutterChangeInCore({
    repoPath: base.repoPath,
    filePath: base.filePath,
    originalStart: change.originalStart,
    originalEnd: change.originalEnd,
    modifiedStart: change.modifiedStart,
    modifiedEnd: change.modifiedEnd,
    originalLines: change.originalLines,
    modifiedLines: change.modifiedLines,
  });
  return result === "applied";
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
    .actions.openBuffer("diff://working-tree/all-files", title, "", false, true, true, multiDiff);
}
