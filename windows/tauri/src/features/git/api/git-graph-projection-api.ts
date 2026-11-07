import { invoke as tauriInvoke } from "@/platform/tauri-core";
import type { GitCommit, GitReference } from "../types/git.types";

// Note: shared/fixtures/git/graph-projection-v1.json defines every rule of
// `git.graphProjection`. Core owns lanes, colors, routes, and labels; this module
// only builds the request and attaches the loaded commits to the returned rows.

export type GitGraphLabelKind = "head" | "branch" | "remote" | "tag";

export interface GitGraphLabel {
  id: string;
  title: string;
  kind: GitGraphLabelKind;
}

export interface GitGraphParentEdge {
  id: string;
  parentHash: string;
  /** Lane in the next row; `null` at the last row. */
  targetLane: number | null;
  /** Signed IDEA color ID, not a palette slot or screen lane. */
  colorId: number;
  isMissing: boolean;
  /** A visible ancestor reached through one or more filtered-out commits. */
  isDotted: boolean;
}

export interface GitGraphPrintElement {
  id: string;
  position: number;
  adjacentPosition: number;
  direction: "up" | "down";
  colorId: number;
  isDotted: boolean;
  isMissing: boolean;
  /** Compact long edges and unloaded parents end with a directional marker. */
  hasArrow: boolean;
  isTerminal: boolean;
  /** Core names loaded endpoints; `attachGitGraphCommits` fills unloaded parents from `parentEdges`. */
  targetHash: string | null;
}

/** One visible commit as Core projects it. */
export interface GitGraphProjectionRow {
  commitHash: string;
  lane: number;
  laneCount: number;
  /** Color ID of the node and its own lane. */
  colorId: number;
  layoutIndex: number;
  incomingLaneColors: number[];
  parentEdges: GitGraphParentEdge[];
  labels: GitGraphLabel[];
  /** Explicit half-edges retain identity, geometry and color for every graph row. */
  printElements: GitGraphPrintElement[];
}

export interface GitGraphProjection {
  version: number;
  rows: GitGraphProjectionRow[];
  laneCount: number;
  /** IDEA's weighted visible-edge width; a baseline, not the widest row. */
  recommendedLaneCount: number;
  hasMissingParents: boolean;
  currentBranchHashes: string[];
}

export type GitGraphDisplayMode = "compact" | "expanded";

export interface GitGraphProjectionRequest {
  commits: Pick<GitCommit, "hash" | "parentHashes" | "decorations">[];
  remoteNames?: string[];
  repositoryCommits?: Pick<GitCommit, "hash" | "parentHashes" | "decorations">[];
  visibleHashes?: string[];
  displayMode?: GitGraphDisplayMode;
  currentBranch?: string;
}

export interface GitGraphRow extends GitGraphProjectionRow {
  commit: GitCommit;
}

export interface GitGraphLayout {
  rows: GitGraphRow[];
  laneCount: number;
  recommendedLaneCount: number;
  hasMissingParents: boolean;
  /** Ancestry of the current branch, for the table's background highlight. */
  currentBranchHashes: ReadonlySet<string>;
}

export interface GitGraphLayoutOptions {
  references?: readonly GitReference[];
  repositoryCommits?: readonly GitCommit[];
  displayMode?: GitGraphDisplayMode;
  /** Ask Core for this local branch's ancestry (`currentBranchHashes`). */
  currentBranch?: string;
}

export const EMPTY_GIT_GRAPH_LAYOUT: GitGraphLayout = {
  rows: [],
  laneCount: 0,
  recommendedLaneCount: 0,
  hasMissingParents: false,
  currentBranchHashes: new Set(),
};

const identity = (commit: GitCommit) => ({
  hash: commit.hash,
  parentHashes: commit.parentHashes,
  decorations: commit.decorations,
});

/** The Core request for one loaded window; the whole window is projected in one call. */
export function buildGitGraphRequest(
  commits: readonly GitCommit[],
  visibleHashes: readonly string[] | undefined,
  options: GitGraphLayoutOptions = {},
): GitGraphProjectionRequest {
  const request: GitGraphProjectionRequest = {
    commits: commits.map(identity),
    displayMode: options.displayMode ?? "compact",
  };
  const remoteNames = options.references
    ?.filter((reference) => reference.kind === "remote")
    .map((reference) => reference.shortName);
  if (remoteNames?.length) request.remoteNames = remoteNames;
  if (options.repositoryCommits?.length) {
    request.repositoryCommits = options.repositoryCommits.map(identity);
  }
  if (visibleHashes) request.visibleHashes = [...visibleHashes];
  if (options.currentBranch) request.currentBranch = options.currentBranch;
  return request;
}

/** Attaches the caller's commit metadata to Core's rows; the first row of a hash wins. */
export function attachGitGraphCommits(
  commits: readonly GitCommit[],
  projection: GitGraphProjection,
): GitGraphLayout {
  const byHash = new Map<string, GitCommit>();
  for (const commit of commits) if (!byHash.has(commit.hash)) byHash.set(commit.hash, commit);
  // Core keeps `targetHash` null on an unloaded parent: the shared contract does
  // not invent a loaded endpoint. It still names that parent in `parentEdges`,
  // and every print element id is `<edge id>:<direction>`. Resolve the locate
  // target over the whole window: Core draws a missing-parent arrow on the row
  // after the edge's source, which has no parent edge of its own.
  const missingTargets = new Map(
    projection.rows.flatMap((row) =>
      row.parentEdges
        .filter((edge) => edge.isMissing)
        .map((edge) => [edge.id, edge.parentHash] as const),
    ),
  );
  return {
    rows: projection.rows.map((row) => {
      const commit = byHash.get(row.commitHash);
      if (!commit) throw new Error(`Git graph projection returned unknown commit ${row.commitHash}`);
      return {
        ...row,
        printElements: row.printElements.map((element) =>
          element.targetHash === null && element.isMissing
            ? {
                ...element,
                targetHash: missingTargets.get(element.id.replace(/:(?:up|down)$/, "")) ?? null,
              }
            : element,
        ),
        commit,
      };
    }),
    laneCount: projection.laneCount,
    recommendedLaneCount: projection.recommendedLaneCount,
    hasMissingParents: projection.hasMissingParents,
    currentBranchHashes: new Set(projection.currentBranchHashes),
  };
}

/** Projects one loaded history window through Core. */
export async function layoutGitGraph(
  commits: readonly GitCommit[],
  visibleHashes?: readonly string[],
  options: GitGraphLayoutOptions = {},
): Promise<GitGraphLayout> {
  if (commits.length === 0) return EMPTY_GIT_GRAPH_LAYOUT;
  const projection = await tauriInvoke<GitGraphProjection>(
    "git.graphProjection",
    buildGitGraphRequest(commits, visibleHashes, options) as unknown as Record<string, unknown>,
  );
  return attachGitGraphCommits(commits, projection);
}
