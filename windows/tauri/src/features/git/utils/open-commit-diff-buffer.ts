import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { getCommitDiff } from "@/features/git/api/git-diff-api";
import type { GitDiff } from "@/features/git/types/git.types";
import type { MultiFileDiff } from "@/features/git/types/git-diff.types";
import { countDiffStats } from "@/features/git/utils/git-diff-helpers";
import { invoke as tauriInvoke } from "@/platform/tauri-core";
import { resolveRepositoryPath } from "@/features/git/api/git-repo-api";

interface OpenCommitDiffBufferOptions {
  repoPath: string;
  commitHash: string;
  message?: string;
  description?: string;
  author?: string;
  date?: string;
  /** Restricts the diff to these workspace-relative paths, e.g. line history. */
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
  const diffs =
    pathspecs || compareReference
      ? await loadScopedCommitDiff(repoPath, commitHash, pathspecs ?? ["."], compareReference)
      : await getCommitDiff(repoPath, commitHash);
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
    hideFileList: pathspecs?.length === 1,
    initialRevealRange,
  };

  const virtualPath =
    pathspecs && pathspecs.length === 1
      ? `diff://commit/${commitHash}/${pathspecs[0]}`
      : `diff://commit/${commitHash}/all-files`;
  const displayName =
    pathspecs && pathspecs.length === 1
      ? `Commit ${shortHash} (${pathspecs[0]})`
      : `Commit ${shortHash} (${diffs.length} files)`;

  return useBufferStore
    .getState()
    .actions.openBuffer(virtualPath, displayName, "", false, undefined, true, true, multiDiff);
};
