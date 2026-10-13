// Portions adapted from JetBrains IntelliJ Community DottedFilterEdgesGenerator,
// Copyright 2000-2024 JetBrains s.r.o. and contributors, Apache-2.0.
// TypeScript adaptation follows macOS GitGraphProjection / GitGraphMissingParents.
// See macos/Resources/GitGraph/NOTICE.txt and the owning Git graph Agent Note.

export interface FilteredGraphEdge {
  up: number;
  down: number | null;
  parentHash: string;
  isDotted: boolean;
}

/** Projects visible endpoints in the original permanent graph's row coordinates. */
export function projectGitGraphFilter(
  hashes: string[],
  parentHashes: string[][],
  parents: number[][],
  children: number[][],
  visible: number[],
): FilteredGraphEdge[] {
  if (visible.length === 0) return [];
  const visibleSet = new Set(visible);
  const knownHashes = new Set(hashes);
  const edges: FilteredGraphEdge[] = [];
  const pairs = new Set<string>();
  const add = (up: number, down: number, isDotted: boolean) => {
    const key = `${up}:${down}`;
    if (up >= down || !visibleSet.has(up) || !visibleSet.has(down) || pairs.has(key)) return;
    pairs.add(key);
    edges.push({ up, down, parentHash: hashes[down], isDotted });
  };

  // Direct edges win over a second path that happens to cross hidden commits.
  for (const row of visible) {
    for (const parent of parents[row]) add(row, parent, false);
    for (const hash of new Set(parentHashes[row])) {
      if (!knownHashes.has(hash))
        edges.push({ up: row, down: null, parentHash: hash, isDotted: false });
    }
  }

  // IntelliJ's two directional nearest-visible walks preserve merge topology
  // without enumerating every path through a hidden diamond.
  const numbers = Array<number>(hashes.length).fill(Number.NEGATIVE_INFINITY);
  for (let node = 0; node < hashes.length; node += 1) {
    let nearest = Number.NEGATIVE_INFINITY;
    let adjacent = Number.NEGATIVE_INFINITY;
    for (const child of children[node]) {
      if (visibleSet.has(child)) {
        if (visibleSet.has(node)) adjacent = Math.max(adjacent, numbers[child]);
        else nearest = Math.max(nearest, child);
      } else nearest = Math.max(nearest, numbers[child]);
    }
    if (visibleSet.has(node)) {
      if (nearest === adjacent || nearest === Number.NEGATIVE_INFINITY) numbers[node] = adjacent;
      else {
        add(nearest, node, true);
        numbers[node] = nearest;
      }
    } else numbers[node] = nearest;
  }
  numbers.fill(Number.POSITIVE_INFINITY);
  for (let node = hashes.length - 1; node >= 0; node -= 1) {
    let nearest = Number.POSITIVE_INFINITY;
    let adjacent = Number.POSITIVE_INFINITY;
    for (const parent of parents[node]) {
      if (visibleSet.has(parent)) {
        if (visibleSet.has(node)) adjacent = Math.min(adjacent, numbers[parent]);
        else nearest = Math.min(nearest, parent);
      } else nearest = Math.min(nearest, numbers[parent]);
    }
    if (visibleSet.has(node)) {
      if (nearest === adjacent || nearest === Number.POSITIVE_INFINITY) numbers[node] = adjacent;
      else {
        add(node, nearest, true);
        numbers[node] = nearest;
      }
    } else numbers[node] = nearest;
  }

  // Share hidden boundary groups rather than copying every ancestor hash set.
  // A visible ancestor owns its continuation; never propagate through it.
  const groups: Array<{ hashes: string[]; parents: number[] }> = [];
  const groupIDs = new Map<string, number>();
  const groupForRow = Array<number | undefined>(hashes.length).fill(undefined);
  for (let row = hashes.length - 1; row >= 0; row -= 1) {
    if (visibleSet.has(row)) continue;
    const missing = [...new Set(parentHashes[row].filter((hash) => !knownHashes.has(hash)))].sort();
    const inherited = [
      ...new Set(
        parents[row].flatMap((parent) => {
          const group = groupForRow[parent];
          return group === undefined ? [] : [group];
        }),
      ),
    ].sort((a, b) => a - b);
    if (missing.length === 0 && inherited.length <= 1) {
      groupForRow[row] = inherited[0];
    } else {
      const key = JSON.stringify([missing, inherited]);
      let id = groupIDs.get(key);
      if (id === undefined) {
        id = groups.length;
        groupIDs.set(key, id);
        groups.push({ hashes: missing, parents: inherited });
      }
      groupForRow[row] = id;
    }
  }
  const visited = Array<number>(groups.length).fill(-1);
  for (const row of visible) {
    const pending = parents[row].flatMap((parent) => {
      const group = groupForRow[parent];
      return group === undefined ? [] : [group];
    });
    const missing = new Set<string>();
    while (pending.length > 0) {
      const id = pending.pop()!;
      if (visited[id] === row) continue;
      visited[id] = row;
      for (const hash of groups[id].hashes) missing.add(hash);
      pending.push(...groups[id].parents);
    }
    const direct = new Set(parentHashes[row]);
    for (const hash of [...missing].sort()) {
      if (!direct.has(hash)) edges.push({ up: row, down: null, parentHash: hash, isDotted: true });
    }
  }
  return edges;
}
