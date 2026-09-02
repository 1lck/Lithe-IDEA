import type { MultiFileDiff } from "../types/git-diff.types";
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
