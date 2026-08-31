import type { GitCommit, GitCommitFile } from "../types/git.types";

export interface GitCommitFileSnapshot {
  commit: GitCommit;
  files: readonly GitCommitFile[];
}

export interface AggregatedGitCommitFiles {
  files: GitCommitFile[];
  commitByPath: Map<string, GitCommit>;
}

export function aggregateGitCommitFiles(
  snapshots: readonly GitCommitFileSnapshot[],
): AggregatedGitCommitFiles {
  const fileByPath = new Map<string, GitCommitFile>();
  const commitByPath = new Map<string, GitCommit>();

  for (const snapshot of snapshots) {
    for (const file of snapshot.files) {
      if (fileByPath.has(file.path)) continue;
      fileByPath.set(file.path, file);
      commitByPath.set(file.path, snapshot.commit);
    }
  }

  return {
    files: [...fileByPath.values()].sort((left, right) => left.path.localeCompare(right.path)),
    commitByPath,
  };
}
