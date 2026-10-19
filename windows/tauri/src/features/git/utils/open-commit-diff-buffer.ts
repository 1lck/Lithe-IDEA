import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { getCommitDiff } from "@/features/git/api/git-diff-api";
import type { GitDiff } from "@/features/git/types/git.types";
import type { MultiFileDiff } from "@/features/git/types/git-diff.types";
import { countDiffStats } from "@/features/git/utils/git-diff-helpers";
import { createCommitFileDiffPreview } from "@/features/git/utils/multi-file-diff";
import { invoke as tauriInvoke } from "@/platform/tauri-core";
import { resolveRepositoryPath } from "@/features/git/api/git-repo-api";

interface OpenCommitDiffBufferOptions {
  repoPath: string;
  commitHash: string;
  message?: string;
  description?: string;
  author?: string;
  date?: string;
  /** Restricts the diff to one workspace-relative path, e.g. line history. */
  pathspecs?: string[];
  /**
   * Explicit `base..target` comparison for entries that must not render as a
   * combined merge diff, such as first-parent line-history entries.
   */
  compareReference?: string;
  /** One-based modified-side lines the opened diff should land on. */
  initialRevealRange?: { startLine: number; endLine: number };
}

/** Loads one commit's diff, optionally scoped by pathspecs or an explicit
 * comparison; dotted `git.diff` carries both without a compatibility command. */
const loadScopedCommitDiff = async (
  repoPath: string,
  commitHash: string,
  pathspecs: string[],
  compareReference?: string,
): Promise<GitDiff[] | null> => {
  const resolved = await resolveRepositoryPath(repoPath);
  if (!resolved) {
    return null;
  }
  return tauriInvoke<GitDiff[]>("git.diff", {
    repoPath: resolved,
    pathspecs,
    ...(compareReference ? { reference: compareReference } : { commit: commitHash }),
  });
};

export const openCommitDiffBuffer = async ({
  repoPath,
  commitHash,
  message,
  description,
  author,
  date,
  pathspecs,
  compareReference,
  initialRevealRange,
}: OpenCommitDiffBufferOptions): Promise<string | null> => {
  // Scoped opens reuse the Git Log single-file preview so the reveal range is
  // actually consumed; the generic stack would ignore positioning entirely.
  // Rename entries carry two pathspecs (previous + current); the target file
  // for the preview is the current one, which is the last entry.
  if (pathspecs?.length === 1 || pathspecs?.length === 2 || compareReference) {
    const diffs = await loadScopedCommitDiff(
      repoPath,
      commitHash,
      pathspecs ?? ["."],
      compareReference,
    );
    if (!diffs || diffs.length === 0) {
      return null;
    }
    const preview = createCommitFileDiffPreview({
      repoPath,
      commitHash,
      diffs,
      filePath: pathspecs?.[pathspecs.length - 1]
        ?? diffs[0]?.new_path
        ?? diffs[0]?.file_path
        ?? "",
      label: commitHash.substring(0, 7),
    });
    if (!preview) {
      return null;
    }
    if (initialRevealRange) {
      preview.diffData.initialRevealRange = initialRevealRange;
    }
    return useBufferStore
      .getState()
      .actions.openBuffer(
        preview.virtualPath,
        preview.displayName,
        "",
        false,
        undefined,
        true,
        true,
        preview.diffData,
      );
  }

  const diffs = await getCommitDiff(repoPath, commitHash);
  if (!diffs || diffs.length === 0) {
    return null;
  }

  const shortHash = commitHash.substring(0, 7);
  const { additions, deletions } = countDiffStats(diffs);
  const multiDiff: MultiFileDiff = {
    title: `Commit ${shortHash}`,
    repoPath,
    commitHash,
    commitMessage: message,
    commitDescription: description,
    commitAuthor: author,
    commitDate: date,
    files: diffs,
    totalFiles: diffs.length,
    totalAdditions: additions,
    totalDeletions: deletions,
  };

  const virtualPath = `diff://commit/${commitHash}/all-files`;
  const displayName = `Commit ${shortHash} (${diffs.length} files)`;

  return useBufferStore
    .getState()
    .actions.openBuffer(virtualPath, displayName, "", false, undefined, true, true, multiDiff);
};
