import { getPathIdentity } from "@/utils/path-helpers";

/** Selection follows visible tree order; checkbox inclusion remains a separate state. */
export function selectTreeEntries(
  selected: ReadonlySet<string>,
  target: string,
  order: readonly string[],
  anchor: string | null,
  modifiers: { additive?: boolean; range?: boolean } = {},
): { selected: Set<string>; anchor: string } {
  const start = anchor ? order.indexOf(anchor) : -1;
  const end = order.indexOf(target);
  if (modifiers.range && start >= 0 && end >= 0) {
    const next = new Set(modifiers.additive ? selected : []);
    for (const id of order.slice(Math.min(start, end), Math.max(start, end) + 1)) next.add(id);
    return { selected: next, anchor: anchor! };
  }
  const next = new Set(modifiers.additive ? selected : []);
  if (modifiers.additive && next.has(target)) next.delete(target);
  else next.add(target);
  return { selected: next, anchor: target };
}

/** WSL, remote and POSIX providers preserve case, including Windows' WSL UNC aliases. */
export const getTreePathIdentity = (path: string): string =>
  getPathIdentity(path).replace(/\/+$/, "");

/** Parent actions already include descendants, so a batch must visit each subtree once. */
export function collapseSelectedTreePaths<T extends { path: string }>(entries: readonly T[]): T[] {
  const ordered = entries.map((entry, index) => ({ path: getTreePathIdentity(entry.path), index }));
  const retained = new Set<number>();
  const selected = new Set(ordered.map((entry) => entry.path));
  const seen = new Set<string>();
  for (const { path, index } of ordered) {
    if (seen.has(path)) continue;
    seen.add(path);
    let parent = path.lastIndexOf("/");
    while (parent >= 0 && !selected.has(path.slice(0, parent))) {
      parent = parent > 0 ? path.lastIndexOf("/", parent - 1) : -1;
    }
    if (parent < 0) retained.add(index);
  }
  return entries.filter((_, index) => retained.has(index));
}

/** Select displayed siblings, including compact package rows, without selecting their subtrees. */
export function selectVisibleTreeSiblings(
  rows: readonly { depth: number; file: { path: string } }[],
  focusedIndex: number,
): Set<string> {
  const focused = rows[focusedIndex];
  if (!focused) return new Set();
  let start = focusedIndex;
  let end = focusedIndex + 1;
  while (start > 0 && rows[start - 1].depth >= focused.depth) start--;
  while (end < rows.length && rows[end].depth >= focused.depth) end++;
  return new Set(
    rows
      .slice(start, end)
      .filter((row) => row.depth === focused.depth)
      .map((row) => row.file.path),
  );
}
