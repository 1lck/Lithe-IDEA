import type { DiffRevisionPair, MultiFileDiff } from "../types/git-diff.types";
import type { GitCommit, GitDiff } from "../types/git.types";
import { countDiffStats } from "./git-diff-helpers";

type MultiFileDiffMetadata = Pick<
  MultiFileDiff,
  "commitMessage" | "commitDescription" | "commitAuthor" | "commitDate"
>;

export function createMultiFileDiff({
  title,
  repoPath,
  commitHash,
  diffs,
  metadata,
  initialFilePath,
  fileKeys,
  fileLabels,
}: {
  title?: string;
  repoPath: string;
  commitHash: string;
  diffs: GitDiff[];
  metadata?: MultiFileDiffMetadata;
  initialFilePath?: string;
  fileKeys?: string[];
  fileLabels?: string[];
}): MultiFileDiff {
  const { additions, deletions } = countDiffStats(diffs);
  const initialFileIndex = initialFilePath
    ? diffs.findIndex((diff) =>
        [diff.file_path, diff.old_path, diff.new_path].some((path) => path === initialFilePath),
      )
    : -1;
  const initialFile = initialFileIndex >= 0 ? diffs[initialFileIndex] : undefined;
  const initialFileKey = initialFile
    ? (fileKeys?.[initialFileIndex] ?? `${initialFile.file_path}:${initialFileIndex}`)
    : undefined;

  return {
    title,
    repoPath,
    commitHash,
    files: diffs,
    totalFiles: diffs.length,
    totalAdditions: additions,
    totalDeletions: deletions,
    fileKeys,
    fileLabels,
    initiallyExpandedFileKey: initialFileKey,
    initiallySelectedFileKey: initialFileKey,
    ...metadata,
  };
}

export function createCommitDiffBuffer({
  repoPath,
  commitHash,
  diffs,
  commit,
  initialFilePath,
}: {
  repoPath: string;
  commitHash: string;
  diffs: GitDiff[];
  commit?: Pick<GitCommit, "message" | "description" | "author" | "date">;
  initialFilePath?: string;
}) {
  const title = `Commit ${commitHash.substring(0, 7)}`;
  const diffData = createMultiFileDiff({
    title,
    repoPath,
    commitHash,
    diffs,
    initialFilePath,
    metadata: {
      commitMessage: commit?.message,
      commitDescription: commit?.description,
      commitAuthor: commit?.author,
      commitDate: commit?.date,
    },
  });

  return {
    virtualPath: `diff://commit/${commitHash}/all-files`,
    displayName: `${title} (${diffs.length} files)`,
    diffData,
  };
}

/** Stable path so every commit-file preview reuses one editor tab instead of opening a new one. */
export const COMMIT_FILE_PREVIEW_PATH = "diff://commit-file-preview";

/**
 * Builds a single-file diff for the commit-files preview. Unlike the commit diff buffer it carries
 * no commit message metadata: the preview shows only the selected file's changes.
 */
export function createCommitFileDiffPreview({
  repoPath,
  commitHash,
  diffs,
  filePath,
  fileKeys,
  fileLabels,
  fileRevisions,
  label,
}: {
  repoPath: string;
  commitHash: string;
  diffs: readonly GitDiff[];
  filePath: string;
  fileKeys?: string[];
  fileLabels?: string[];
  fileRevisions?: DiffRevisionPair[];
  /** Revision identity shown in the page, never appended to the repository preview tab. */
  label: string;
}) {
  const selected = diffs.find((diff) =>
    [diff.new_path, diff.file_path, diff.old_path].includes(filePath),
  );
  if (!selected) return null;
  const fileName = (selected.new_path || selected.file_path || selected.old_path || filePath)
    .split(/[\\/]/)
    .pop()!;
  const diffData = createMultiFileDiff({
    title: fileName,
    repoPath,
    commitHash,
    // Retain every revision and its key, including repeated paths. Only the selected
    // entry is rendered; file navigation must not refetch or lose revision identity.
    diffs: [...diffs],
    initialFilePath: filePath,
    fileKeys,
    fileLabels: fileLabels ?? diffs.map(() => label),
  });
  diffData.hideFileList = true;
  diffData.commitFilePreview = true;
  diffData.fileRevisions = fileRevisions;

  return {
    virtualPath: COMMIT_FILE_PREVIEW_PATH,
    displayName: `Repository Diff: ${fileName}`,
    diffData,
  };
}
