import { nanoid } from "nanoid";
import { DEFAULT_SPLIT_RATIO, MIN_PANE_SIZE } from "../constants/pane";
import type {
  PaneGroup,
  PaneNode,
  PaneSplit,
  SplitDirection,
  SplitPlacement,
} from "../types/pane.types";
import { reduceWorkbenchGroups, type WorkbenchAction } from "./workbench-state";

export interface FlatPaneEntry {
  node: PaneNode;
  size: number;
  path: Array<{ splitId: string; childIndex: 0 | 1 }>;
}

/** Builds a group whose members, selection and MRU order Core has already made consistent. */
export function createPaneGroup(
  bufferIds: string[] = [],
  activeBufferId: string | null = null,
): PaneGroup {
  const draft: PaneGroup = { id: nanoid(), type: "group", bufferIds, activeBufferId };
  const { groups } = reduceWorkbenchGroups([draft], { kind: "normalize" });
  const [group] = groups;
  return {
    id: draft.id,
    type: "group",
    bufferIds: group.bufferIds,
    activeBufferId: group.activeBufferId,
    mruBufferIds: group.mruBufferIds,
  };
}

export function createPaneSplit(
  direction: SplitDirection,
  first: PaneNode,
  second: PaneNode,
  sizes: [number, number] = DEFAULT_SPLIT_RATIO,
): PaneSplit {
  const safeSizes = normalizeSplitSizes(sizes);
  return {
    id: nanoid(),
    type: "split",
    direction,
    children: [first, second],
    sizes: safeSizes,
  };
}

function normalizeSplitSizes(sizes: [number, number]): [number, number] {
  const first = Number.isFinite(sizes[0]) ? sizes[0] : DEFAULT_SPLIT_RATIO[0];
  const second = Number.isFinite(sizes[1]) ? sizes[1] : DEFAULT_SPLIT_RATIO[1];
  const total = first + second;

  if (total <= 0) return DEFAULT_SPLIT_RATIO;

  const normalized: [number, number] = [(first / total) * 100, (second / total) * 100];
  const min = Math.min(MIN_PANE_SIZE, 49);

  if (normalized[0] < min) return [min, 100 - min];
  if (normalized[1] < min) return [100 - min, min];

  return normalized;
}

function updatePaneNode(
  root: PaneNode,
  nodeId: string,
  update: (node: PaneNode) => PaneNode,
): PaneNode {
  if (root.id === nodeId) {
    return update(root);
  }

  if (root.type !== "split") {
    return root;
  }

  const first = updatePaneNode(root.children[0], nodeId, update);
  if (first !== root.children[0]) {
    return {
      ...root,
      children: [first, root.children[1]],
    };
  }

  const second = updatePaneNode(root.children[1], nodeId, update);
  if (second !== root.children[1]) {
    return {
      ...root,
      children: [root.children[0], second],
    };
  }

  return root;
}

function mapPaneGroups(root: PaneNode, update: (group: PaneGroup) => PaneGroup): PaneNode {
  if (root.type === "group") {
    return update(root);
  }

  const first = mapPaneGroups(root.children[0], update);
  const second = mapPaneGroups(root.children[1], update);
  if (first === root.children[0] && second === root.children[1]) {
    return root;
  }
  return { ...root, children: [first, second] };
}

/**
 * Runs one Core action over every group of `roots` that `involves` selects, in a single Core
 * call, and writes the returned groups back. Groups Core removed are reported for the caller to
 * prune from its layout (see {@link removePaneGroups}); they are left in the trees until then.
 */
function reduceGroupsInTrees(
  roots: PaneNode[],
  involves: (group: PaneGroup) => boolean,
  action: WorkbenchAction,
): { roots: PaneNode[]; removedGroupIds: string[] } {
  const selected = new Map<string, PaneGroup>();
  for (const root of roots) {
    for (const group of getAllPaneGroups(root)) {
      if (involves(group)) selected.set(group.id, group);
    }
  }
  if (selected.size === 0) {
    return { roots, removedGroupIds: [] };
  }

  const { groups, removedGroupIds } = reduceWorkbenchGroups([...selected.values()], action);
  const next = new Map(groups.map((group) => [group.id, group]));
  return {
    roots: roots.map((root) => mapPaneGroups(root, (group) => next.get(group.id) ?? group)),
    removedGroupIds,
  };
}

/** Closes the layout nodes of groups Core removed; null means the tree has no group left. */
export function removePaneGroups(root: PaneNode, paneIds: string[]): PaneNode | null {
  let next: PaneNode | null = root;
  for (const paneId of paneIds) {
    if (!next) break;
    next = closePane(next, paneId);
  }
  return next;
}

function reduceGroupInTree(root: PaneNode, paneId: string, action: WorkbenchAction): PaneNode {
  return reduceGroupsInTrees([root], (group) => group.id === paneId, action).roots[0];
}

/** Normalizes the groups of several trees with one Core call (split ratios are normalized here). */
export function normalizePaneTrees(roots: PaneNode[]): PaneNode[] {
  const { roots: normalized } = reduceGroupsInTrees(roots, () => true, { kind: "normalize" });
  return normalized.map(normalizeSplitSizesInTree);
}

function normalizeSplitSizesInTree(root: PaneNode): PaneNode {
  if (root.type === "group") {
    return root;
  }

  return {
    ...root,
    sizes: normalizeSplitSizes(root.sizes),
    children: [
      normalizeSplitSizesInTree(root.children[0]),
      normalizeSplitSizesInTree(root.children[1]),
    ],
  };
}

export function normalizePaneTree(root: PaneNode): PaneNode {
  return normalizePaneTrees([root])[0];
}

export function flattenPaneSplit(
  split: PaneSplit,
  parentSize: number = 100,
  path: Array<{ splitId: string; childIndex: 0 | 1 }> = [],
): FlatPaneEntry[] {
  const entries: FlatPaneEntry[] = [];

  for (let i = 0; i < 2; i++) {
    const child = split.children[i as 0 | 1];
    const childSize = (split.sizes[i as 0 | 1] / 100) * parentSize;
    const childPath = [...path, { splitId: split.id, childIndex: i as 0 | 1 }];

    if (child.type === "split" && child.direction === split.direction) {
      entries.push(...flattenPaneSplit(child, childSize, childPath));
    } else {
      entries.push({ node: child, size: childSize, path: childPath });
    }
  }

  return entries;
}

function writeFlatSizesToTree(entries: FlatPaneEntry[], root: PaneNode): PaneNode {
  const splitTotals = new Map<string, { first: number; second: number }>();

  for (const entry of entries) {
    for (const step of entry.path) {
      if (!splitTotals.has(step.splitId)) {
        splitTotals.set(step.splitId, { first: 0, second: 0 });
      }
    }
  }

  for (const entry of entries) {
    for (const step of entry.path) {
      const totals = splitTotals.get(step.splitId)!;
      if (step.childIndex === 0) {
        totals.first += entry.size;
      } else {
        totals.second += entry.size;
      }
    }
  }

  let nextRoot = root;
  for (const [splitId, totals] of splitTotals) {
    const sum = totals.first + totals.second;
    if (sum <= 0) continue;
    nextRoot = updatePaneSizes(nextRoot, splitId, [
      (totals.first / sum) * 100,
      (totals.second / sum) * 100,
    ]);
  }

  return nextRoot;
}

export function resizeFlattenedPaneSplit(
  root: PaneNode,
  splitId: string,
  index: number,
  sizes: [number, number],
): PaneNode {
  const split = findPaneNode(root, splitId);
  if (!split || split.type !== "split") return root;

  const entries = flattenPaneSplit(split);
  if (index < 0 || index >= entries.length - 1) return root;

  const nextSizes = entries.map((entry) => entry.size);
  const pairTotal = entries[index].size + entries[index + 1].size;
  const normalizedSizes = normalizeSplitSizes(sizes);
  nextSizes[index] = (normalizedSizes[0] / 100) * pairTotal;
  nextSizes[index + 1] = (normalizedSizes[1] / 100) * pairTotal;

  return writeFlatSizesToTree(
    entries.map((entry, entryIndex) => ({
      ...entry,
      size: nextSizes[entryIndex],
    })),
    root,
  );
}

export function distributeFlattenedPaneSplit(root: PaneNode, splitId: string): PaneNode {
  const split = findPaneNode(root, splitId);
  if (!split || split.type !== "split") return root;

  const entries = flattenPaneSplit(split);
  if (entries.length === 0) return root;

  const totalSize = entries.reduce((sum, entry) => sum + entry.size, 0);
  const equalSize = totalSize / entries.length;

  return writeFlatSizesToTree(
    entries.map((entry) => ({
      ...entry,
      size: equalSize,
    })),
    root,
  );
}

export function findPaneNode(root: PaneNode, paneId: string): PaneNode | null {
  if (root.id === paneId) {
    return root;
  }

  if (root.type === "split") {
    const inFirst = findPaneNode(root.children[0], paneId);
    if (inFirst) return inFirst;
    return findPaneNode(root.children[1], paneId);
  }

  return null;
}

export function findPaneGroup(root: PaneNode, paneId: string): PaneGroup | null {
  const node = findPaneNode(root, paneId);
  if (node && node.type === "group") {
    return node;
  }
  return null;
}

export function findPaneGroupByBufferId(root: PaneNode, bufferId: string): PaneGroup | null {
  if (root.type === "group") {
    if (root.bufferIds.includes(bufferId)) {
      return root;
    }
    return null;
  }

  const inFirst = findPaneGroupByBufferId(root.children[0], bufferId);
  if (inFirst) return inFirst;
  return findPaneGroupByBufferId(root.children[1], bufferId);
}

function collectPaneGroups(root: PaneNode, groups: PaneGroup[]) {
  if (root.type === "group") {
    groups.push(root);
    return;
  }

  collectPaneGroups(root.children[0], groups);
  collectPaneGroups(root.children[1], groups);
}

export function getAllPaneGroups(root: PaneNode): PaneGroup[] {
  const groups: PaneGroup[] = [];
  collectPaneGroups(root, groups);
  return groups;
}

export function getFirstPaneGroup(root: PaneNode): PaneGroup {
  if (root.type === "group") {
    return root;
  }
  return getFirstPaneGroup(root.children[0]);
}

export function splitPane(
  root: PaneNode,
  paneId: string,
  direction: SplitDirection,
  bufferId?: string,
  placement: SplitPlacement = "after",
): PaneNode {
  return updatePaneNode(root, paneId, (node) => {
    if (node.type !== "group") {
      return node;
    }

    const newGroup = createPaneGroup(bufferId ? [bufferId] : [], bufferId ?? null);
    return placement === "before"
      ? createPaneSplit(direction, newGroup, node)
      : createPaneSplit(direction, node, newGroup);
  });
}

export function closePane(root: PaneNode, paneId: string): PaneNode | null {
  if (root.id === paneId) {
    return null;
  }

  if (root.type === "split") {
    if (root.children[0].id === paneId) {
      return root.children[1];
    }
    if (root.children[1].id === paneId) {
      return root.children[0];
    }

    const newFirst = closePane(root.children[0], paneId);
    const newSecond = closePane(root.children[1], paneId);

    if (newFirst === null) {
      return root.children[1];
    }
    if (newSecond === null) {
      return root.children[0];
    }

    if (newFirst !== root.children[0] || newSecond !== root.children[1]) {
      return {
        ...root,
        children: [newFirst, newSecond],
      };
    }
  }

  return root;
}

export function updatePaneSizes(
  root: PaneNode,
  splitId: string,
  sizes: [number, number],
): PaneNode {
  return updatePaneNode(root, splitId, (node) =>
    node.type === "split" ? { ...node, sizes: normalizeSplitSizes(sizes) } : node,
  );
}

export function addBufferToPane(
  root: PaneNode,
  paneId: string,
  bufferId: string,
  setActive: boolean = true,
): PaneNode {
  return reduceGroupInTree(root, paneId, {
    kind: "open",
    group: paneId,
    member: bufferId,
    activate: setActive,
  });
}

/**
 * Removes a tab from a group. With `pruneEmptyPane` the group is closed when it becomes empty;
 * null means that was the tree's only group and the caller supplies a fresh root.
 */
export function removeBufferFromPane(
  root: PaneNode,
  paneId: string,
  bufferId: string,
  pruneEmptyPane: boolean = false,
): PaneNode | null {
  const reduced = reduceGroupsInTrees([root], (group) => group.id === paneId, {
    kind: "close",
    group: paneId,
    member: bufferId,
    emptyGroups: pruneEmptyPane ? "remove" : "keep",
    selectionFallback: "adjacent",
  });
  return removePaneGroups(reduced.roots[0], reduced.removedGroupIds);
}

/**
 * Moves a tab between two groups, which may live in different trees (`fromRoot`, `toRoot`; the
 * same object when they share one). Core does the whole transition in one call. A null root means
 * that tree lost its last group.
 */
export function moveBufferBetweenPanes(
  fromRoot: PaneNode,
  toRoot: PaneNode,
  bufferId: string,
  fromPaneId: string,
  toPaneId: string,
  pruneEmptySource: boolean = true,
): { fromRoot: PaneNode | null; toRoot: PaneNode | null } {
  const sameTree = fromRoot === toRoot;
  const reduced = reduceGroupsInTrees(
    sameTree ? [fromRoot] : [fromRoot, toRoot],
    (group) => group.id === fromPaneId || group.id === toPaneId,
    {
      kind: "move",
      member: bufferId,
      from: fromPaneId,
      to: toPaneId,
      activate: true,
      emptyGroups: pruneEmptySource ? "remove" : "keep",
      selectionFallback: "adjacent",
    },
  );
  const next = reduced.roots.map((root) => removePaneGroups(root, reduced.removedGroupIds));
  return { fromRoot: next[0], toRoot: sameTree ? next[0] : next[1] };
}

/**
 * Folds the tabs of a group that was just closed into another group of `root` and optionally
 * shows the tab the closed group was showing.
 */
export function mergeClosedPaneInto(
  root: PaneNode,
  closedPane: PaneGroup,
  intoPaneId: string,
  activateSelected: boolean,
): PaneNode {
  const target = findPaneGroup(root, intoPaneId);
  if (!target) return root;
  const { groups } = reduceWorkbenchGroups([closedPane, target], {
    kind: "mergeGroup",
    from: closedPane.id,
    into: intoPaneId,
    activateSelected,
  });
  const merged = groups.find((group) => group.id === intoPaneId);
  return merged ? mapPaneGroups(root, (group) => (group.id === intoPaneId ? merged : group)) : root;
}

export function setActivePaneBuffer(
  root: PaneNode,
  paneId: string,
  bufferId: string | null,
): PaneNode {
  return reduceGroupInTree(root, paneId, { kind: "activate", group: paneId, member: bufferId });
}

export function setPanePreviewBuffer(
  root: PaneNode,
  paneId: string,
  bufferId: string | null,
): PaneNode {
  return reduceGroupInTree(root, paneId, { kind: "setPreview", group: paneId, member: bufferId });
}

/** Clears a preview of `bufferId` in every group of every tree, with one Core call. */
export function clearPanePreviewBufferEverywhere(roots: PaneNode[], bufferId: string): PaneNode[] {
  return reduceGroupsInTrees(roots, (group) => group.previewBufferId === bufferId, {
    kind: "clearPreviewEverywhere",
    member: bufferId,
  }).roots;
}

export function setPaneBufferPinned(
  root: PaneNode,
  paneId: string,
  bufferId: string,
  pinned: boolean,
): PaneNode {
  return reduceGroupInTree(root, paneId, {
    kind: "setPinned",
    group: paneId,
    member: bufferId,
    pinned,
  });
}

/** Pins or unpins `bufferId` in every group that lists it, across trees, with one Core call. */
export function setPaneBufferPinnedEverywhere(
  roots: PaneNode[],
  bufferId: string,
  pinned: boolean,
): PaneNode[] {
  return reduceGroupsInTrees(roots, (group) => group.bufferIds.includes(bufferId), {
    kind: "setPinnedEverywhere",
    member: bufferId,
    pinned,
  }).roots;
}

export function setPaneLocked(root: PaneNode, paneId: string, locked: boolean): PaneNode {
  const normalized = reduceGroupInTree(root, paneId, { kind: "normalize" });
  return mapPaneGroups(normalized, (group) => (group.id === paneId ? { ...group, locked } : group));
}

export function reorderPaneBuffers(
  root: PaneNode,
  paneId: string,
  startIndex: number,
  endIndex: number,
): PaneNode {
  return reduceGroupInTree(root, paneId, {
    kind: "reorder",
    group: paneId,
    fromIndex: startIndex,
    toIndex: endIndex,
  });
}

export function getAdjacentPane(
  root: PaneNode,
  currentPaneId: string,
  direction: "left" | "right" | "up" | "down",
): PaneGroup | null {
  interface PaneRect {
    pane: PaneGroup;
    left: number;
    top: number;
    right: number;
    bottom: number;
  }

  const rects: PaneRect[] = [];

  const visit = (node: PaneNode, left: number, top: number, right: number, bottom: number) => {
    if (node.type === "group") {
      rects.push({ pane: node, left, top, right, bottom });
      return;
    }

    const [firstSize, secondSize] = node.sizes;
    const total = firstSize + secondSize || 100;

    if (node.direction === "horizontal") {
      const splitX = left + ((right - left) * firstSize) / total;
      visit(node.children[0], left, top, splitX, bottom);
      visit(node.children[1], splitX, top, right, bottom);
      return;
    }

    const splitY = top + ((bottom - top) * firstSize) / total;
    visit(node.children[0], left, top, right, splitY);
    visit(node.children[1], left, splitY, right, bottom);
  };

  const overlapLength = (aStart: number, aEnd: number, bStart: number, bEnd: number) =>
    Math.max(0, Math.min(aEnd, bEnd) - Math.max(aStart, bStart));

  visit(root, 0, 0, 100, 100);

  const currentRect = rects.find((entry) => entry.pane.id === currentPaneId);
  if (!currentRect) return null;

  let bestCandidate: PaneRect | null = null;
  let bestDistance = Number.POSITIVE_INFINITY;
  let bestOverlap = -1;

  for (const candidate of rects) {
    if (candidate.pane.id === currentPaneId) continue;

    let distance = Number.POSITIVE_INFINITY;
    let overlap = 0;

    if (direction === "left") {
      if (candidate.right > currentRect.left) continue;
      distance = currentRect.left - candidate.right;
      overlap = overlapLength(currentRect.top, currentRect.bottom, candidate.top, candidate.bottom);
    } else if (direction === "right") {
      if (candidate.left < currentRect.right) continue;
      distance = candidate.left - currentRect.right;
      overlap = overlapLength(currentRect.top, currentRect.bottom, candidate.top, candidate.bottom);
    } else if (direction === "up") {
      if (candidate.bottom > currentRect.top) continue;
      distance = currentRect.top - candidate.bottom;
      overlap = overlapLength(currentRect.left, currentRect.right, candidate.left, candidate.right);
    } else {
      if (candidate.top < currentRect.bottom) continue;
      distance = candidate.top - currentRect.bottom;
      overlap = overlapLength(currentRect.left, currentRect.right, candidate.left, candidate.right);
    }

    if (overlap <= 0) continue;

    if (distance < bestDistance || (distance === bestDistance && overlap > bestOverlap)) {
      bestCandidate = candidate;
      bestDistance = distance;
      bestOverlap = overlap;
    }
  }

  return bestCandidate?.pane ?? null;
}
