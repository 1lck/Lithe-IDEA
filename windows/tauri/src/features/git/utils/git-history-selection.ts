export interface GitHistorySelectionUpdate {
  selected: Set<string>;
  anchor: string;
}

export function updateGitHistorySelection(
  visibleCommitHashes: readonly string[],
  selectedCommitHashes: ReadonlySet<string>,
  commitHash: string,
  anchorHash: string | null,
  options: { additive: boolean; range: boolean },
): GitHistorySelectionUpdate {
  if (!options.range) {
    if (!options.additive) {
      return { selected: new Set([commitHash]), anchor: commitHash };
    }
    const selected = new Set(selectedCommitHashes);
    if (selected.has(commitHash)) selected.delete(commitHash);
    else selected.add(commitHash);
    return { selected, anchor: commitHash };
  }

  const anchorIndex = anchorHash ? visibleCommitHashes.indexOf(anchorHash) : -1;
  const commitIndex = visibleCommitHashes.indexOf(commitHash);
  if (anchorIndex < 0 || commitIndex < 0) {
    return { selected: new Set([commitHash]), anchor: commitHash };
  }

  const start = Math.min(anchorIndex, commitIndex);
  const end = Math.max(anchorIndex, commitIndex);
  const selected = options.additive ? new Set(selectedCommitHashes) : new Set<string>();
  visibleCommitHashes.slice(start, end + 1).forEach((hash) => selected.add(hash));
  return { selected, anchor: anchorHash ?? commitHash };
}

export function resolveGitHistoryContextSelection(
  selectedCommitHashes: ReadonlySet<string>,
  commitHash: string,
): Set<string> {
  return selectedCommitHashes.has(commitHash)
    ? new Set(selectedCommitHashes)
    : new Set([commitHash]);
}

export function selectedCommitsInHistoryOrder<T extends { hash: string }>(
  commits: readonly T[],
  selectedCommitHashes: ReadonlySet<string>,
): T[] {
  return commits.filter((commit) => selectedCommitHashes.has(commit.hash));
}

export function isContiguousGitHistorySelection(
  commits: readonly { hash: string }[],
  selectedCommitHashes: ReadonlySet<string>,
): boolean {
  if (selectedCommitHashes.size < 2) return false;
  const indices = commits.flatMap((commit, index) =>
    selectedCommitHashes.has(commit.hash) ? [index] : [],
  );
  return (
    indices.length === selectedCommitHashes.size &&
    indices[indices.length - 1] - indices[0] + 1 === indices.length
  );
}
