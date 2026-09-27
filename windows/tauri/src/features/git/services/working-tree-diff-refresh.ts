import equal from "fast-deep-equal";
import { normalizePath } from "@/utils/path-helpers";
import { getWorkingTreePathDiff } from "../api/git-diff-api";
import { getGitStatus } from "../api/git-status-api";
import type { MultiFileDiff, WorkingTreeDiffTarget } from "../types/git-diff.types";
import type { GitDiff, GitFile, GitStatus } from "../types/git.types";
import {
  getGitFileOriginalRepositoryRelativePath,
  getGitFileRepositoryRelativePath,
} from "../utils/git-status-selection";
import { createSingleFileWorkingTreeDiff } from "../utils/working-tree-multi-diff";

export type WorkingTreeDiffRefreshOutcome = "updated" | "unchanged" | "closed" | "skipped";

/** Editor buffer access for one working-tree diff; the editor owns the store. */
export interface WorkingTreeDiffBufferPort {
  /** Returns the buffer's working-tree diff, or null when it no longer shows one. */
  read: (bufferId: string) => MultiFileDiff | null;
  replace: (bufferId: string, diff: MultiFileDiff) => void;
  close: (bufferId: string) => void;
}

export interface WorkingTreeDiffRefreshDependencies {
  buffers: WorkingTreeDiffBufferPort;
  loadStatus?: (repoPath: string) => Promise<GitStatus | null>;
  loadDiff?: (
    repoPath: string,
    filePath: string,
    untracked: boolean,
    originalPath?: string,
  ) => Promise<GitDiff | null>;
}

function findStatusFile(status: GitStatus, target: WorkingTreeDiffTarget): GitFile | undefined {
  const targetRepoPath = normalizePath(target.repoPath);
  return status.files.find(
    (file) =>
      getGitFileRepositoryRelativePath(file) === target.filePath &&
      (!file.repositoryPath || normalizePath(file.repositoryPath) === targetRepoPath),
  );
}

function hasRenderableDiff(diff: GitDiff): boolean {
  return diff.lines.length > 0 || diff.is_image === true || diff.is_binary === true;
}

/**
 * Reloads one working-tree file diff after a Git change, matching the macOS
 * contract: the view reloads in place with the same repository, path, and
 * HEAD-to-worktree semantics used to open it, shows an empty state when the
 * file has no remaining diff, and closes only when Git status no longer lists
 * the file. Failed reads keep the current content instead of closing.
 */
export async function refreshWorkingTreeFileDiff(
  {
    bufferId,
    fileKey,
  }: {
    bufferId: string;
    fileKey: string;
  },
  {
    buffers,
    loadStatus = getGitStatus,
    loadDiff = getWorkingTreePathDiff,
  }: WorkingTreeDiffRefreshDependencies,
): Promise<WorkingTreeDiffRefreshOutcome> {
  const startingDiff = buffers.read(bufferId);
  const target = startingDiff?.workingTreeTargets?.[fileKey];
  if (!startingDiff || !target) return "skipped";

  // A newer open, progressive load, or refresh owns the buffer once its diff
  // data is replaced, so stale results must not overwrite it.
  const isCurrent = () => buffers.read(bufferId) === startingDiff;

  const status = await loadStatus(target.repoPath);
  if (!isCurrent() || !status) return "skipped";

  const statusFile = findStatusFile(status, target);
  if (!statusFile) {
    buffers.close(bufferId);
    return "closed";
  }

  const originalPath = getGitFileOriginalRepositoryRelativePath(statusFile) ?? target.originalPath;
  const nextTarget: WorkingTreeDiffTarget = {
    repoPath: target.repoPath,
    filePath: target.filePath,
    ...(originalPath ? { originalPath } : {}),
    untracked: statusFile.status === "untracked",
  };
  const diff = await loadDiff(
    nextTarget.repoPath,
    nextTarget.filePath,
    nextTarget.untracked,
    nextTarget.originalPath,
  );
  if (!isCurrent() || !diff) return "skipped";

  const nextDiff = createSingleFileWorkingTreeDiff({
    repoPath: startingDiff.repoPath ?? nextTarget.repoPath,
    fileKey,
    diff: hasRenderableDiff(diff) ? diff : null,
    title: startingDiff.title,
    target: nextTarget,
  });
  // Git metadata changes often leave the file untouched. Replacing the buffer
  // anyway rebuilds the review editor and disturbs the reader's scroll position.
  if (
    equal(nextDiff.files, startingDiff.files) &&
    equal(nextDiff.workingTreeTargets, startingDiff.workingTreeTargets)
  ) {
    return "unchanged";
  }

  buffers.replace(bufferId, nextDiff);
  return "updated";
}
