import type { GitCommit, GitCommitFile, GitDiff } from "../types/git.types";

export type GitCommitSelectionDiff =
  | { kind: "commit"; commit: GitCommit }
  | { kind: "selection"; commits: readonly GitCommit[] }
  | {
      kind: "range";
      baseRef: string | null;
      targetRef: string;
      oldest: GitCommit;
      newest: GitCommit;
    };

export interface GitSelectedCommitDiffAggregate {
  files: GitCommitFile[];
  diffs: GitDiff[];
  fileKeys: string[];
  fileLabels: string[];
}

export function aggregateSelectedCommitFileRows(
  results: readonly { files: readonly GitCommitFile[] }[],
): GitCommitFile[] {
  const fileByPath = new Map<string, GitCommitFile>();
  for (const result of results) {
    for (const file of result.files) {
      if (!fileByPath.has(file.path)) fileByPath.set(file.path, file);
    }
  }
  return [...fileByPath.values()].sort((left, right) => left.path.localeCompare(right.path));
}

/** Resolves commits ordered newest-first into the snapshot shown by the inspector. */
export function resolveGitCommitSelectionDiff(
  commits: readonly GitCommit[],
): GitCommitSelectionDiff | null {
  const newest = commits[0];
  if (!newest) return null;
  if (commits.length === 1) return { kind: "commit", commit: newest };

  const isFirstParentChain = commits.every(
    (commit, index) =>
      index === commits.length - 1 || commit.parentHashes[0] === commits[index + 1].hash,
  );
  if (!isFirstParentChain) return { kind: "selection", commits };

  const oldest = commits[commits.length - 1];
  return {
    kind: "range",
    baseRef: oldest.parentHashes[0] ?? null,
    targetRef: newest.hash,
    oldest,
    newest,
  };
}

export function aggregateSelectedCommitDiffs(
  results: readonly { commit: GitCommit; diffs: readonly GitDiff[] }[],
): GitSelectedCommitDiffAggregate {
  const fileByPath = new Map<string, GitCommitFile>();
  const diffs: GitDiff[] = [];
  const fileKeys: string[] = [];
  const fileLabels: string[] = [];
  for (const result of results) {
    for (const [index, diff] of result.diffs.entries()) {
      const file = gitDiffToCommitFile(diff);
      diffs.push(diff);
      fileKeys.push(`${result.commit.hash}:${file.path}:${index}`);
      fileLabels.push(result.commit.shortHash);
      if (!fileByPath.has(file.path)) fileByPath.set(file.path, file);
    }
  }
  return {
    files: [...fileByPath.values()].sort((left, right) => left.path.localeCompare(right.path)),
    diffs,
    fileKeys,
    fileLabels,
  };
}

export function gitDiffsToCommitFiles(diffs: readonly GitDiff[]): GitCommitFile[] {
  return diffs
    .map(gitDiffToCommitFile)
    .sort((left, right) => left.path.localeCompare(right.path));
}

function gitDiffToCommitFile(diff: GitDiff): GitCommitFile {
  return {
    path: diff.new_path || diff.file_path,
    status: diff.is_renamed ? "R" : diff.is_new ? "A" : diff.is_deleted ? "D" : "M",
  };
}
