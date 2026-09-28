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
  /** Color of the commit node and its own lane. */
  colorIndex: number;
  laneCount: number;
  /** Lanes entering the row from above; the node's lane is null for a branch tip. */
  incomingLaneColors: Array<number | null>;
  parentEdges: GitGraphEdge[];
  labels: GitGraphLabel[];
}

export interface GitGraphLayout {
  rows: GitGraphRow[];
  laneCount: number;
  hasMissingParents: boolean;
}

interface GraphEdge {
  up: number;
  down: number | null;
  parentHash: string;
  id: string;
}

type GraphElement = { kind: "node"; row: number } | { kind: "edge"; edge: number };

function stableElementKey(element: GraphElement): number {
  return element.kind === "node" ? -1 : element.edge;
}

export function parseGitDecorations(decorations: string): GitGraphLabel[] {
  return decorations.split(",").flatMap((value): GitGraphLabel[] => {
    const raw = value.trim();
    if (!raw) return [];
    if (raw === "HEAD") return [{ title: "HEAD", kind: "head" }];
    if (raw.startsWith("HEAD -> ")) {
      return [
        { title: "HEAD", kind: "head" },
        { title: localBranchName(raw.slice("HEAD -> ".length)), kind: "branch" },
      ];
    }
    if (raw.startsWith("tag: ")) return [{ title: raw.slice("tag: ".length), kind: "tag" }];
    if (raw.startsWith("refs/tags/")) {
      return [{ title: raw.slice("refs/tags/".length), kind: "tag" }];
    }
    if (raw.startsWith("origin/") || raw.startsWith("refs/remotes/")) {
      return [
        {
          title: raw.startsWith("refs/remotes/")
            ? raw.slice("refs/remotes/".length)
            : raw,
          kind: "remote",
        },
      ];
    }
    return [{ title: localBranchName(raw), kind: "branch" }];
  });
}

function localBranchName(name: string): string {
  return name.startsWith("refs/heads/") ? name.slice("refs/heads/".length) : name;
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

/** The natural-name ordering used by IntelliJ's Git reference comparator. */
function naturalCompare(left: string, right: string, ignoreCase = true): number {
  const a = Array.from({ length: left.length }, (_, index) => left.charCodeAt(index));
  const b = Array.from({ length: right.length }, (_, index) => right.charCodeAt(index));
  let i = 0;
  let j = 0;
  const isDigit = (value: number) => value >= 48 && value <= 57;
  const simpleCaseUnit = (value: number, uppercase: boolean) => {
    if (value >= 0x61 && value <= 0x7a) return uppercase ? value - 0x20 : value;
    if (value >= 0x41 && value <= 0x5a) return uppercase ? value : value + 0x20;
    const mapped = String.fromCharCode(value)[uppercase ? "toUpperCase" : "toLowerCase"]();
    return mapped.length === 1 ? mapped.charCodeAt(0) : value;
  };

  while (i < a.length && j < b.length) {
    const first = a[i];
    const second = b[j];
    if ((isDigit(first) || first === 32) && (isDigit(second) || second === 32)) {
      let firstStart = i;
      while (firstStart < a.length && a[firstStart] === 32) firstStart += 1;
      while (firstStart < a.length && a[firstStart] === 48) firstStart += 1;
      let firstEnd = firstStart;
      while (firstEnd < a.length && isDigit(a[firstEnd])) firstEnd += 1;

      let secondStart = j;
      while (secondStart < b.length && b[secondStart] === 32) secondStart += 1;
      while (secondStart < b.length && b[secondStart] === 48) secondStart += 1;
      let secondEnd = secondStart;
      while (secondEnd < b.length && isDigit(b[secondEnd])) secondEnd += 1;

      const firstLength = firstEnd - firstStart;
      const secondLength = secondEnd - secondStart;
      if (firstLength !== secondLength) return firstLength - secondLength;
      for (let offset = 0; offset < firstLength; offset += 1) {
        const difference = a[firstStart + offset] - b[secondStart + offset];
        if (difference !== 0) return difference;
      }
      const lengthDifference = firstEnd - i - (secondEnd - j);
      if (lengthDifference !== 0) return lengthDifference;
      for (let offset = 0; offset < firstStart - i; offset += 1) {
        const difference = a[i + offset] - b[j + offset];
        if (difference !== 0) return difference;
      }
      i = firstEnd;
      j = secondEnd;
      continue;
    }

    if (first === 32 && second > 32 && second < 48) return 1;
    if (second === 32 && first > 32 && first < 48) return -1;
    let difference = first - second;
    if (difference !== 0 && ignoreCase) {
      const upperDifference = simpleCaseUnit(first, true) - simpleCaseUnit(second, true);
      difference = upperDifference !== 0
        ? upperDifference
        : simpleCaseUnit(first, false) - simpleCaseUnit(second, false);
    }
    if (difference !== 0) return difference;
    i += 1;
    j += 1;
  }
  if (i < a.length) return 1;
  if (j < b.length) return -1;
  if (a.length !== b.length) return a.length - b.length;
  return ignoreCase ? naturalCompare(left, right, false) : 0;
}

function compareGraphLabels(left: GitGraphLabel, right: GitGraphLabel): number {
  const priorityDifference = graphLabelPriority(left) - graphLabelPriority(right);
  return priorityDifference !== 0 ? priorityDifference : naturalCompare(left.title, right.title);
}

export function bestGraphReferenceLabel(labels: GitGraphLabel[]): GitGraphLabel | null {
  let best: GitGraphLabel | null = null;
  for (const label of labels) {
    if (best === null || compareGraphLabels(label, best) < 0) best = label;
  }
  return best;
}

function sortedHeads(labels: GitGraphLabel[][], children: number[][]): number[] {
  return labels
    .map((value, index) => ({ index, labels: value, best: bestGraphReferenceLabel(value) }))
    .filter(({ index, labels: value }) =>
      children[index].length === 0 || value.some((label) => label.kind !== "tag"),
    )
    .sort((left, right) => {
      if (left.best && right.best) {
        const comparison = compareGraphLabels(left.best, right.best);
        return comparison !== 0 ? comparison : left.index - right.index;
      }
      if (left.best) return -1;
      if (right.best) return 1;
      return left.index - right.index;
    })
    .map(({ index }) => index);
}

/**
 * Reproduces the permanent layout used by macOS's IntelliJ-compatible graph.
 * The graph head order is intentionally independent from the screen columns:
 * a parent branch reference can therefore keep its color when a local branch
 * is added on top of it.
 */
function permanentLayout(
  labels: GitGraphLabel[][],
  parents: number[][],
  children: number[][],
): { indices: number[]; colors: number[] } {
  const indices = Array<number>(parents.length).fill(0);
  const colors = Array<number>(parents.length).fill(0);
  const nextParent = Array<number>(parents.length).fill(0);
  let layoutIndex = 1;

  for (const head of sortedHeads(labels, children)) {
    if (indices[head] !== 0) continue;
    const stack = [head];
    const headIndex = layoutIndex;
    const headReference = bestGraphReferenceLabel(labels[head]);
    const headColor = headReference ? graphColorIndexForName(headReference.title) : 0;

    while (stack.length > 0) {
      const node = stack[stack.length - 1];
      const firstVisit = indices[node] === 0;
      if (firstVisit) {
        indices[node] = layoutIndex;
        colors[node] = layoutIndex === headIndex ? headColor : layoutIndex;
      }
      while (
        nextParent[node] < parents[node].length &&
        indices[parents[node][nextParent[node]]] !== 0
      ) {
        nextParent[node] += 1;
      }
      if (nextParent[node] < parents[node].length) {
        stack.push(parents[node][nextParent[node]]);
      } else {
        if (firstVisit) layoutIndex += 1;
        stack.pop();
      }
    }
  }

  // A well-formed Git history always has a head for every component. Keep a
  // deterministic fallback for incomplete snapshots or defensive fixtures.
  for (let node = 0; node < parents.length; node += 1) {
    if (indices[node] !== 0) continue;
    const stack = [node];
    const headIndex = layoutIndex;
    while (stack.length > 0) {
      const current = stack[stack.length - 1];
      if (indices[current] === 0) {
        indices[current] = layoutIndex;
        colors[current] = layoutIndex === headIndex ? 0 : layoutIndex;
      }
      while (
        nextParent[current] < parents[current].length &&
        indices[parents[current][nextParent[current]]] !== 0
      ) {
        nextParent[current] += 1;
      }
      if (nextParent[current] < parents[current].length) stack.push(parents[current][nextParent[current]]);
      else {
        layoutIndex += 1;
        stack.pop();
      }
    }
  }

  return { indices, colors };
}

function compareEdgeToNode(
  edge: GraphEdge,
  node: number,
  indices: number[],
): number {
  const nodeIndex = indices[node];
  if (edge.down === null) return indices[edge.up] - nodeIndex;
  const edgeIndex = Math.max(indices[edge.up], indices[edge.down]);
  return edgeIndex !== nodeIndex ? edgeIndex - nodeIndex : edge.up - node;
}

function compareElements(
  left: GraphElement,
  right: GraphElement,
  edges: GraphEdge[],
  indices: number[],
): number {
  if (left.kind === "node" && right.kind === "node") return 0;
  if (left.kind === "edge" && right.kind === "node") {
    return compareEdgeToNode(edges[left.edge], right.row, indices);
  }
  if (left.kind === "node" && right.kind === "edge") {
    return -compareEdgeToNode(edges[right.edge], left.row, indices);
  }
  if (left.kind === "node" || right.kind === "node") return 0;

  const first = edges[left.edge];
  const second = edges[right.edge];
  if (first.down === null) return -compareEdgeToNode(second, first.up, indices);
  if (second.down === null) return compareEdgeToNode(first, second.up, indices);
  if (first.up === second.up) {
    return first.down < second.down
      ? -compareEdgeToNode(second, first.down, indices)
      : compareEdgeToNode(first, second.down, indices);
  }
  return first.up < second.up
    ? compareEdgeToNode(first, second.up, indices)
    : -compareEdgeToNode(second, first.up, indices);
}

// Note: IntelliJ graph parity and cross-platform ownership are documented in
// .agents/notes/implemented/feature/2026-09-25-windows-git-graph-branch-colors.md.
export function layoutGitGraph(commits: GitCommit[]): GitGraphLayout {
  if (commits.length === 0) return { rows: [], laneCount: 0, hasMissingParents: false };

  const firstRowByHash = new Map<string, number>();
  for (const [row, commit] of commits.entries()) {
    if (!firstRowByHash.has(commit.hash)) firstRowByHash.set(commit.hash, row);
  }

  const labelsByRow = commits.map((commit) => parseGitDecorations(commit.decorations));
  const parents = commits.map(() => [] as number[]);
  const children = commits.map(() => [] as number[]);
  const edges: GraphEdge[] = [];

  for (const [row, commit] of commits.entries()) {
    const seenParents = new Set<number>();
    const seenMissingParents = new Set<string>();
    for (const [parentIndex, parentHash] of commit.parentHashes.entries()) {
      const parent = firstRowByHash.get(parentHash);
      if (parent === undefined || parent <= row || !seenParents.add(parent)) {
        if (parent === undefined && seenMissingParents.add(parentHash)) {
          edges.push({
            up: row,
            down: null,
            parentHash,
            id: `${row}:${parentHash}:missing`,
          });
        }
        continue;
      }
      parents[row].push(parent);
      children[parent].push(row);
      edges.push({
        up: row,
        down: parent,
        parentHash,
        id: `${row}:${parent}:${parentHash}:${parentIndex}`,
      });
    }
  }

  const { indices, colors } = permanentLayout(labelsByRow, parents, children);
  edges.sort((left, right) => {
    if (left.up !== right.up) return left.up - right.up;
    if (left.down !== right.down) return (left.down ?? Number.MAX_SAFE_INTEGER) - (right.down ?? Number.MAX_SAFE_INTEGER);
    return left.parentHash < right.parentHash ? -1 : left.parentHash > right.parentHash ? 1 : 0;
  });

  const elements: GraphElement[][] = commits.map((_, row) => [{ kind: "node" as const, row }]);
  const adjacent: number[][] = commits.map(() => []);
  for (const [edgeIndex, edge] of edges.entries()) {
    adjacent[edge.up].push(edgeIndex);
    if (edge.down !== null) {
      adjacent[edge.down].push(edgeIndex);
      const span = edge.down - edge.up;
      if (span > 1) {
        if (span < 30) {
          for (let row = edge.up + 1; row < edge.down; row += 1) {
            elements[row].push({ kind: "edge", edge: edgeIndex });
          }
        } else {
          elements[edge.up + 1].push({ kind: "edge", edge: edgeIndex });
          elements[edge.down - 1].push({ kind: "edge", edge: edgeIndex });
        }
      }
    } else if (edge.up + 1 < commits.length) {
      elements[edge.up + 1].push({ kind: "edge", edge: edgeIndex });
    }
  }

  const positions = elements.map(() => new Map<number, number>());
  const nodePositions = Array<number>(commits.length).fill(0);
  for (let row = 0; row < elements.length; row += 1) {
    const rowElements = elements[row];
    rowElements.sort((left, right) => {
      const order = compareElements(left, right, edges, indices);
      return order === 0 ? stableElementKey(left) - stableElementKey(right) : order;
    });
    elements[row] = rowElements;
    rowElements.forEach((element, position) => {
      if (element.kind === "node") {
        nodePositions[row] = position;
        for (const edge of adjacent[row]) positions[row].set(edge, position);
      } else {
        positions[row].set(element.edge, position);
      }
    });
  }

  const edgeColor = (edge: GraphEdge): number => {
    if (edge.down === null) return colors[edge.up];
    return indices[edge.up] > indices[edge.down] ? colors[edge.up] : colors[edge.down];
  };

  const rows: GitGraphRow[] = commits.map((commit, row) => {
    const incomingLaneColors = elements[row].map((element) =>
      element.kind === "edge"
        ? edgeColor(edges[element.edge])
        : adjacent[row].some((edge) => edges[edge].down === row)
          ? colors[row]
          : null,
    );
    const parentEdges = adjacent[row]
      .filter((edgeIndex) => edges[edgeIndex].up === row)
      .map((edgeIndex) => {
        const edge = edges[edgeIndex];
        return {
          id: edge.id,
          parentHash: edge.parentHash,
          targetLane: row + 1 < commits.length ? (positions[row + 1].get(edgeIndex) ?? null) : null,
          colorIndex: edgeColor(edge),
          isMissing: edge.down === null,
        };
      });
    return {
      commit,
      lane: nodePositions[row],
      colorIndex: colors[row],
      laneCount: elements[row].length,
      incomingLaneColors,
      parentEdges,
      labels: labelsByRow[row],
    };
  });

  return {
    rows,
    laneCount: Math.max(1, ...rows.map((row) => row.laneCount)),
    hasMissingParents: edges.some((edge) => edge.down === null),
  };
}
