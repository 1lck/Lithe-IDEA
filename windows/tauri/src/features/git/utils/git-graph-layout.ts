import type { GitCommit } from "../types/git.types";
import { graphColorIndexForName } from "./git-graph-colors";

export type GitGraphLabelKind = "head" | "branch" | "remote" | "tag";

export interface GitGraphLabel {
  title: string;
  kind: GitGraphLabelKind;
}

export interface GitGraphEdge {
  id: string;
  parentHash: string;
  targetLane: number | null;
  colorIndex: number;
  isMissing: boolean;
}

export interface GitGraphRow {
  commit: GitCommit;
  lane: number;
  laneCount: number;
  incomingLaneColors: Array<number | null>;
  parentEdges: GitGraphEdge[];
  labels: GitGraphLabel[];
}

export interface GitGraphLayout {
  rows: GitGraphRow[];
  laneCount: number;
  hasMissingParents: boolean;
}

interface Lane {
  hash: string;
  colorIndex: number;
}

function claimSlot(slots: Array<Lane | null>): number {
  const freeSlot = slots.findIndex((slot) => slot === null);
  if (freeSlot >= 0) return freeSlot;
  slots.push(null);
  return slots.length - 1;
}

export function parseGitDecorations(decorations: string): GitGraphLabel[] {
  return decorations.split(",").flatMap((value): GitGraphLabel[] => {
    const raw = value.trim();
    if (!raw) return [];
    if (raw === "HEAD") return [{ title: "HEAD", kind: "head" }];
    if (raw.startsWith("HEAD -> ")) {
      return [
        { title: "HEAD", kind: "head" },
        { title: raw.slice("HEAD -> ".length), kind: "branch" },
      ];
    }
    if (raw.startsWith("tag: ")) return [{ title: raw.slice("tag: ".length), kind: "tag" }];
    if (raw.startsWith("refs/tags/")) {
      return [{ title: raw.slice("refs/tags/".length), kind: "tag" }];
    }
    if (raw.startsWith("origin/") || raw.startsWith("refs/remotes/")) {
      return [
        {
          title: raw.startsWith("refs/remotes/") ? raw.slice("refs/remotes/".length) : raw,
          kind: "remote",
        },
      ];
    }
    return [{ title: raw, kind: "branch" }];
  });
}

/**
 * IDEA's GraphColorGetterByHead picks a head's principal reference in this
 * order, so the same branch name always yields the same color id.
 */
function graphLabelPriority(label: GitGraphLabel): number {
  if (label.kind === "remote") {
    return label.title === "origin/main" || label.title === "origin/master" ? 0 : 1;
  }
  if (label.kind === "branch") {
    return label.title === "main" || label.title === "master" ? 2 : 3;
  }
  return label.kind === "tag" ? 4 : 6;
}

export function bestGraphReferenceLabel(labels: GitGraphLabel[]): GitGraphLabel | null {
  let best: GitGraphLabel | null = null;
  for (const label of labels) {
    if (best === null) {
      best = label;
      continue;
    }
    const bestPriority = graphLabelPriority(best);
    const priority = graphLabelPriority(label);
    if (priority < bestPriority || (priority === bestPriority && label.title < best.title)) {
      best = label;
    }
  }
  return best;
}

export function layoutGitGraph(commits: GitCommit[]): GitGraphLayout {
  if (commits.length === 0) return { rows: [], laneCount: 0, hasMissingParents: false };

  const knownHashes = new Set(commits.map((commit) => commit.hash));
  const slots: Array<Lane | null> = [];
  const rows: GitGraphRow[] = [];
  let nextFallbackColorIndex = 0;
  let maximumLaneCount = 0;
  let hasMissingParents = false;

  const labelsByHash = new Map<string, GitGraphLabel[]>();
  const namedColorIndexByHash = new Map<string, number>();
  for (const commit of commits) {
    const labels = parseGitDecorations(commit.decorations);
    labelsByHash.set(commit.hash, labels);
    const reference = bestGraphReferenceLabel(labels);
    if (reference) {
      namedColorIndexByHash.set(commit.hash, graphColorIndexForName(reference.title));
    }
  }
  // A branch's color follows its name; a lane without a reference still needs a
  // deterministic color so unreferenced fragments stay stable across renders.
  const fallbackColorIndex = () => nextFallbackColorIndex++;
  const colorIndexForHash = (hash: string) =>
    namedColorIndexByHash.get(hash) ?? fallbackColorIndex();

  for (const commit of commits) {
    let currentLane = slots.findIndex((slot) => slot?.hash === commit.hash);
    if (currentLane < 0) {
      currentLane = claimSlot(slots);
      slots[currentLane] = { hash: commit.hash, colorIndex: colorIndexForHash(commit.hash) };
    }

    const incomingLaneColors = slots.map((slot) => slot?.colorIndex ?? null);
    const currentColorIndex = slots[currentLane]?.colorIndex ?? 0;
    slots[currentLane] = null;

    const parentEdges: GitGraphEdge[] = [];
    commit.parentHashes.forEach((parentHash, parentIndex) => {
      if (!knownHashes.has(parentHash)) {
        hasMissingParents = true;
        parentEdges.push({
          id: `${commit.hash}:${parentIndex}:${parentHash}`,
          parentHash,
          targetLane: null,
          colorIndex: parentIndex === 0 ? currentColorIndex : fallbackColorIndex(),
          isMissing: true,
        });
        return;
      }

      let targetLane = slots.findIndex((slot) => slot?.hash === parentHash);
      let colorIndex: number;
      if (targetLane >= 0) {
        colorIndex = slots[targetLane]?.colorIndex ?? currentColorIndex;
      } else if (parentIndex === 0) {
        targetLane = currentLane;
        colorIndex = currentColorIndex;
        slots[targetLane] = { hash: parentHash, colorIndex };
      } else {
        targetLane = claimSlot(slots);
        colorIndex = colorIndexForHash(parentHash);
        slots[targetLane] = { hash: parentHash, colorIndex };
      }

      parentEdges.push({
        id: `${commit.hash}:${parentIndex}:${parentHash}`,
        parentHash,
        targetLane,
        colorIndex,
        isMissing: false,
      });
    });

    while (slots.length > 0 && slots[slots.length - 1] === null) slots.pop();
    const edgeLaneCount = Math.max(-1, ...parentEdges.map((edge) => edge.targetLane ?? -1)) + 1;
    const laneCount = Math.max(
      incomingLaneColors.length,
      slots.length,
      currentLane + 1,
      edgeLaneCount,
    );
    maximumLaneCount = Math.max(maximumLaneCount, laneCount);
    rows.push({
      commit,
      lane: currentLane,
      laneCount,
      incomingLaneColors,
      parentEdges,
      labels: labelsByHash.get(commit.hash) ?? [],
    });
  }

  return { rows, laneCount: Math.max(1, maximumLaneCount), hasMissingParents };
}
