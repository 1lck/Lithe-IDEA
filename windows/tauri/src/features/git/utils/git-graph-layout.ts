import type { GitCommit, GitReference } from "../types/git.types";
import { graphColorIdForName } from "./git-graph-colors";
import { projectGitGraphFilter } from "./git-graph-filter-projection";

export type GitGraphLabelKind = "head" | "branch" | "remote" | "tag";

export interface GitGraphLabel {
  title: string;
  kind: GitGraphLabelKind;
}

export interface GitGraphEdge {
  id: string;
  parentHash: string;
  targetLane: number | null;
  /** Signed IDEA color ID, not a palette slot or screen lane. */
  colorIndex: number;
  isMissing: boolean;
  /** A visible ancestor reached through one or more filtered-out commits. */
  isDotted: boolean;
}

export interface GitGraphPrintElement {
  id: string;
  position: number;
  adjacentPosition: number;
  direction: "up" | "down";
  colorIndex: number;
  isDotted: boolean;
  isMissing: boolean;
  /** Compact long edges and unloaded parents end with a directional marker. */
  hasArrow: boolean;
  isTerminal: boolean;
  /** Loaded visible endpoint; missing history never invents a navigation target. */
  targetHash: string | null;
}

export interface GitGraphRow {
  commit: GitCommit;
  lane: number;
  /** Color of the commit node and its own lane. */
  colorIndex: number;
  laneCount: number;
  /** Row-center color summary for structural diagnostics, never a drawing route. */
  incomingLaneColors: Array<number | null>;
  parentEdges: GitGraphEdge[];
  labels: GitGraphLabel[];
  /** Explicit half-edges retain identity, geometry and color for every graph row. */
  printElements: GitGraphPrintElement[];
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
  isDotted: boolean;
}

type GraphElement = { kind: "node"; row: number } | { kind: "edge"; edge: number };

export const GIT_GRAPH_DISPLAY_OPTIONS = {
  compact: { longEdgeSize: 30, visiblePartSize: 1, edgeWithArrowSize: Infinity },
  expanded: { longEdgeSize: 1_000, visiblePartSize: 250, edgeWithArrowSize: 30 },
} as const;

export interface GitGraphLayoutOptions {
  references?: readonly GitReference[];
  repositoryCommits?: readonly GitCommit[];
  displayMode?: keyof typeof GIT_GRAPH_DISPLAY_OPTIONS;
}

function stableElementKey(element: GraphElement): number {
  return element.kind === "node" ? -1 : element.edge;
}

export function parseGitDecorations(
  decorations: string,
  remoteNames: ReadonlySet<string> = new Set(),
): GitGraphLabel[] {
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
    if (remoteNames.has(raw) || raw.startsWith("origin/") || raw.startsWith("refs/remotes/")) {
      return [
        {
          title: raw.startsWith("refs/remotes/") ? raw.slice("refs/remotes/".length) : raw,
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
export function naturalCompare(left: string, right: string, ignoreCase = true): number {
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
      difference =
        upperDifference !== 0
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
    .filter(
      ({ index, labels: value }) =>
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
    const headColor = headReference ? graphColorIdForName(headReference.title) : 0;

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
      if (nextParent[current] < parents[current].length)
        stack.push(parents[current][nextParent[current]]);
      else {
        layoutIndex += 1;
        stack.pop();
      }
    }
  }

  return { indices, colors };
}

function compareEdgeToNode(edge: GraphEdge, node: number, indices: number[]): number {
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
export function layoutGitGraph(
  inputCommits: GitCommit[],
  visibleHashes?: ReadonlySet<string>,
  options: GitGraphLayoutOptions = {},
): GitGraphLayout {
  let commits = inputCommits;
  if (commits.length === 0) return { rows: [], laneCount: 0, hasMissingParents: false };

  const remoteNames = new Set(
    options.references
      ?.filter((reference) => reference.kind === "remote")
      .map((reference) => reference.shortName),
  );
  const display = GIT_GRAPH_DISPLAY_OPTIONS[options.displayMode ?? "compact"];
  const context = options.repositoryCommits ?? [];
  const contextRows = new Map(context.map((commit, row) => [commit.hash, row]));
  let contextPermanent: ReturnType<typeof permanentLayout> | undefined;
  // Match macOS: use only a unique context covering every scoped commit.
  // A bounded-context miss falls back to the page; it never drops old commits.
  if (
    context.length > 0 &&
    contextRows.size === context.length &&
    commits.every((commit) => contextRows.has(commit.hash))
  ) {
    const contextParents = context.map(() => [] as number[]);
    const contextChildren = context.map(() => [] as number[]);
    context.forEach((commit, row) => {
      for (const hash of new Set(commit.parentHashes)) {
        const parent = contextRows.get(hash);
        if (parent === undefined || parent <= row) continue;
        contextParents[row].push(parent);
        contextChildren[parent].push(row);
      }
    });
    contextPermanent = permanentLayout(
      context.map((commit) => parseGitDecorations(commit.decorations, remoteNames)),
      contextParents,
      contextChildren,
    );
    const scoped = new Map<string, GitCommit>();
    for (const commit of commits) if (!scoped.has(commit.hash)) scoped.set(commit.hash, commit);
    commits = context.flatMap((commit) =>
      scoped.has(commit.hash) ? [scoped.get(commit.hash)!] : [],
    );
  }

  const firstRowByHash = new Map<string, number>();
  for (const [row, commit] of commits.entries()) {
    if (!firstRowByHash.has(commit.hash)) firstRowByHash.set(commit.hash, row);
  }

  const labelsByRow = commits.map((commit) => parseGitDecorations(commit.decorations, remoteNames));
  const parents = commits.map(() => [] as number[]);
  const children = commits.map(() => [] as number[]);
  let edges: GraphEdge[] = [];

  for (const [row, commit] of commits.entries()) {
    const seenParents = new Set<number>();
    const seenMissingParents = new Set<string>();
    for (const [parentIndex, parentHash] of commit.parentHashes.entries()) {
      const parent = firstRowByHash.get(parentHash);
      if (parent === undefined || parent <= row || seenParents.has(parent)) {
        if (parent === undefined && !seenMissingParents.has(parentHash)) {
          seenMissingParents.add(parentHash);
          edges.push({
            up: row,
            down: null,
            parentHash,
            id: `${row}:${parentHash}:missing`,
            isDotted: false,
          });
        }
        continue;
      }
      seenParents.add(parent);
      parents[row].push(parent);
      children[parent].push(row);
      edges.push({
        up: row,
        down: parent,
        parentHash,
        id: `${row}:${parent}:${parentHash}:${parentIndex}`,
        isDotted: false,
      });
    }
  }

  const permanent = contextPermanent
    ? {
        indices: commits.map((commit) => contextPermanent!.indices[contextRows.get(commit.hash)!]),
        colors: commits.map((commit) => contextPermanent!.colors[contextRows.get(commit.hash)!]),
      }
    : permanentLayout(labelsByRow, parents, children);
  const visible = commits.flatMap((commit, row) =>
    visibleHashes === undefined ||
    (visibleHashes.has(commit.hash) && firstRowByHash.get(commit.hash) === row)
      ? [row]
      : [],
  );
  if (visible.length === 0) return { rows: [], laneCount: 0, hasMissingParents: false };
  const visibleCommits = visible.map((row) => commits[row]);
  const indices = visible.map((row) => permanent.indices[row]);
  const colors = visible.map((row) => permanent.colors[row]);
  if (visibleHashes !== undefined) {
    const visibleRows = new Map(visible.map((row, index) => [row, index]));
    edges = projectGitGraphFilter(
      commits.map((commit) => commit.hash),
      commits.map((commit) => commit.parentHashes),
      parents,
      children,
      visible,
    ).map((edge) => ({
      ...edge,
      id: `${commits[edge.up].hash}:${edge.parentHash}:${edge.isDotted ? "filtered" : "direct"}`,
      up: visibleRows.get(edge.up)!,
      down: edge.down === null ? null : visibleRows.get(edge.down)!,
    }));
  }
  edges.sort((left, right) => {
    if (left.up !== right.up) return left.up - right.up;
    if (left.down !== right.down)
      return (left.down ?? Number.MAX_SAFE_INTEGER) - (right.down ?? Number.MAX_SAFE_INTEGER);
    return left.parentHash < right.parentHash ? -1 : left.parentHash > right.parentHash ? 1 : 0;
  });

  const elements: GraphElement[][] = visibleCommits.map((_, row) => [
    { kind: "node" as const, row },
  ]);
  const adjacent: number[][] = visibleCommits.map(() => []);
  for (const [edgeIndex, edge] of edges.entries()) {
    adjacent[edge.up].push(edgeIndex);
    if (edge.down !== null) {
      adjacent[edge.down].push(edgeIndex);
      const span = edge.down - edge.up;
      if (span > 1) {
        if (span < display.longEdgeSize) {
          for (let row = edge.up + 1; row < edge.down; row += 1) {
            elements[row].push({ kind: "edge", edge: edgeIndex });
          }
        } else {
          for (let row = edge.up + 1; row <= edge.up + display.visiblePartSize; row += 1) {
            elements[row].push({ kind: "edge", edge: edgeIndex });
          }
          for (let row = edge.down - display.visiblePartSize; row < edge.down; row += 1) {
            elements[row].push({ kind: "edge", edge: edgeIndex });
          }
        }
      }
    } else if (edge.up + 1 < visibleCommits.length) {
      elements[edge.up + 1].push({ kind: "edge", edge: edgeIndex });
    }
  }

  const positions = elements.map(() => new Map<number, number>());
  const nodePositions = Array<number>(visibleCommits.length).fill(0);
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

  const rows: GitGraphRow[] = visibleCommits.map((commit, row) => {
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
          targetLane:
            row + 1 < visibleCommits.length ? (positions[row + 1].get(edgeIndex) ?? null) : null,
          colorIndex: edgeColor(edge),
          isMissing: edge.down === null,
          isDotted: edge.isDotted,
        };
      });
    // PrintElementGeneratorImpl: both halves keep the same edge identity and
    // boundary midpoint; incoming colors must never be inferred from the node.
    const printElements = elements[row].flatMap((element, position) => {
      const ids = element.kind === "edge" ? [element.edge] : adjacent[row];
      return ids.flatMap((id) => {
        const edge = edges[id];
        return (["up", "down"] as const).flatMap((direction): GitGraphPrintElement[] => {
          const next = row + (direction === "up" ? -1 : 1);
          const nextPosition = positions[next]?.get(id);
          const hasArrow =
            edge.down === null
              ? direction === "down" && row === edge.up + 1
              : (edge.down - edge.up >= display.longEdgeSize &&
                  (direction === "down" ? row - edge.up : edge.down - row) ===
                    display.visiblePartSize) ||
                (edge.down - edge.up >= display.edgeWithArrowSize &&
                  (direction === "down" ? row - edge.up : edge.down - row) === 1);
          // Missing-parent markers belong on the next row. Never invent
          // a continuation above a tip or below the last visible node.
          if (nextPosition === undefined && !hasArrow) return [];
          return [
            {
              id: `${edge.id}:${direction}`,
              position,
              adjacentPosition: nextPosition ?? position,
              direction,
              colorIndex: edgeColor(edge),
              isDotted: edge.isDotted,
              isMissing: edge.down === null,
              hasArrow,
              isTerminal: nextPosition === undefined,
              targetHash:
                edge.down === null
                  ? null
                  : visibleCommits[direction === "down" ? edge.down : edge.up].hash,
            },
          ];
        });
      });
    });
    return {
      commit,
      lane: nodePositions[row],
      colorIndex: colors[row],
      laneCount: elements[row].length,
      incomingLaneColors,
      parentEdges,
      labels: labelsByRow[visible[row]],
      printElements,
    };
  });

  return {
    rows,
    laneCount: Math.max(1, ...rows.map((row) => row.laneCount)),
    hasMissingParents: edges.some((edge) => edge.down === null),
  };
}
