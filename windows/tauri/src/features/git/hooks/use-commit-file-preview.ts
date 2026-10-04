import { useCallback, useLayoutEffect, useRef } from "react";
import { getCommitDiff, getRefDiff } from "../api/git-diff-api";
import type { DiffRevisionPair, MultiFileDiff } from "../types/git-diff.types";
import type { GitDiff } from "../types/git.types";
import { mapGitReadsInBatches } from "../utils/git-async-batch";
import {
  aggregateSelectedCommitDiffs,
  type GitCommitSelectionDiff,
} from "../utils/git-commit-selection-diff";
import { createCommitFileDiffPreview } from "../utils/multi-file-diff";
import { createRequestGeneration } from "../utils/request-generation";

/** Owns automatic preview publication for one visible Git Log selection. */
export function useCommitFilePreview(
  repoPath: string | null,
  scopeKey: string | null,
  openPreview: (path: string, name: string, data: MultiFileDiff) => unknown,
) {
  const requests = useRef(createRequestGeneration());
  // Invalidate before passive effects can start a preview for the new selection.
  // Cleanup also prevents a closed/unmounted Log from activating a global editor buffer.
  useLayoutEffect(() => {
    requests.current.begin();
    return () => {
      requests.current.begin();
    };
  }, [repoPath, scopeKey]);

  return useCallback(
    async (selection: GitCommitSelectionDiff, filePath: string) => {
      if (!repoPath || scopeKey === null) return;
      const requestId = requests.current.begin();
      try {
        let diffs: readonly GitDiff[] | null;
        let commitHash: string;
        let label: string;
        let fileKeys: string[] | undefined;
        let fileLabels: string[] | undefined;
        let fileRevisions: DiffRevisionPair[];
        if (selection.kind === "commit") {
          diffs = await getCommitDiff(repoPath, selection.commit.hash);
          commitHash = selection.commit.hash;
          label = selection.commit.shortHash;
          fileRevisions = (diffs ?? []).map(() => ({
            before: selection.commit.parentHashes[0] ?? null,
            after: selection.commit.hash,
          }));
        } else if (selection.kind === "range") {
          diffs = await getRefDiff(repoPath, selection.baseRef, selection.targetRef);
          commitHash = `${selection.baseRef ?? "root"}..${selection.targetRef}`;
          label = `${selection.oldest.shortHash}..${selection.newest.shortHash}`;
          fileRevisions = (diffs ?? []).map(() => ({ before: selection.baseRef, after: selection.targetRef }));
        } else {
          const results = await mapGitReadsInBatches(selection.commits, async (commit) => ({
            commit,
            diffs: await getCommitDiff(repoPath, commit.hash),
          }));
          if (results.some((result) => result.diffs === null)) return;
          const aggregate = aggregateSelectedCommitDiffs(
            results.map((result) => ({ commit: result.commit, diffs: result.diffs ?? [] })),
          );
          diffs = aggregate.diffs;
          fileKeys = aggregate.fileKeys;
          fileLabels = aggregate.fileLabels;
          fileRevisions = results.flatMap(({ commit, diffs }) => (diffs ?? []).map(() => ({
            before: commit.parentHashes[0] ?? null,
            after: commit.hash,
          })));
          commitHash = selection.commits[0]?.hash ?? "selection";
          label = String(selection.commits.length);
        }
        if (!requests.current.isCurrent(requestId) || !diffs) return;
        const preview = createCommitFileDiffPreview({
          repoPath,
          commitHash,
          diffs,
          filePath,
          fileKeys,
          fileLabels,
          fileRevisions,
          label,
        });
        if (preview) openPreview(preview.virtualPath, preview.displayName, preview.diffData);
      } catch (error) {
        console.error("Error previewing commit file diff:", error);
      }
    },
    [repoPath, scopeKey, openPreview],
  );
}
