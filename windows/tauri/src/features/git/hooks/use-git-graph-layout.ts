import { useEffect, useMemo, useState } from "react";
import {
  EMPTY_GIT_GRAPH_LAYOUT,
  layoutGitGraph,
  type GitGraphDisplayMode,
  type GitGraphLayout,
} from "../api/git-graph-projection-api";
import type { GitCommit, GitReference } from "../types/git.types";

/**
 * Projects the loaded history window through Core (`git.graphProjection`).
 *
 * The whole window is projected in one call whenever its commits, the filter, the
 * display mode, or the reference set change. Keeping the previous layout until the
 * next one arrives avoids a blank graph while a page loads, and a response for a
 * superseded request is discarded.
 */
export function useGitGraphLayout(input: {
  commits: readonly GitCommit[];
  repositoryCommits?: readonly GitCommit[];
  references?: readonly GitReference[];
  /** `undefined` shows every commit. */
  visibleHashes?: readonly string[];
  displayMode: GitGraphDisplayMode;
  currentBranch?: string;
}): GitGraphLayout {
  const { commits, repositoryCommits, references, visibleHashes, displayMode, currentBranch } =
    input;
  const [layout, setLayout] = useState<GitGraphLayout>(EMPTY_GIT_GRAPH_LAYOUT);
  // Hashes are compared by content so a new array with the same filter result is not a change.
  const visibleKey = useMemo(() => visibleHashes?.join("\n"), [visibleHashes]);
  useEffect(() => {
    let current = true;
    layoutGitGraph(commits, visibleHashes, {
      references,
      repositoryCommits,
      displayMode,
      currentBranch,
    }).then(
      (next) => {
        if (current) setLayout(next);
      },
      (error) => {
        console.error("Failed to project the Git graph:", error);
        if (current) setLayout(EMPTY_GIT_GRAPH_LAYOUT);
      },
    );
    return () => {
      current = false;
    };
  }, [commits, repositoryCommits, references, visibleKey, displayMode, currentBranch]);
  return layout;
}
