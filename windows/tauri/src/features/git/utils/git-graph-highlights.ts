import type { GitCommit, GitReference } from "../types/git.types";
import { parseGitDecorations } from "./git-graph-layout";

/** Matches macOS currentBranchHashes: membership includes every merge parent. */
export function currentGitBranchHashes(
  commits: readonly GitCommit[],
  repositoryCommits: readonly GitCommit[],
  references: readonly GitReference[],
): ReadonlySet<string> {
  const branch = references.find((reference) => reference.kind === "local" && reference.isCurrent);
  if (!branch) return new Set();
  const values = [...commits, ...repositoryCommits];
  const remoteNames = new Set(
    references
      .filter((reference) => reference.kind === "remote")
      .map((reference) => reference.shortName),
  );
  const head = values.find((commit) =>
    parseGitDecorations(commit.decorations, remoteNames).some(
      (label) => label.kind === "branch" && label.title === branch.shortName,
    ),
  );
  if (!head) return new Set();
  const byHash = new Map<string, GitCommit>();
  for (const commit of values) if (!byHash.has(commit.hash)) byHash.set(commit.hash, commit);
  const pending = [head.hash];
  const hashes = new Set<string>();
  while (pending.length) {
    const hash = pending.pop()!;
    if (hashes.has(hash)) continue;
    hashes.add(hash);
    pending.push(...(byHash.get(hash)?.parentHashes ?? []));
  }
  return hashes;
}

/** A current-branch/HEAD-only view already identifies its branch. */
export function shouldHighlightCurrentGitBranch(reference?: GitReference | null): boolean {
  return !reference || (!reference.isCurrent && reference.shortName !== "HEAD");
}
