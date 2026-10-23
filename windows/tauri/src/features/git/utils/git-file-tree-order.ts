import { buildPathTree, type PathTreeNode } from "@/features/sidebar/lib/path-tree";
import type { GitDiff } from "../types/git.types";
import { compareGitFileNames } from "./natural-file-name-compare";

/** Indices of `items` in the order the Git file tree renders them: directory
 * nodes before file nodes at every level, names compared with IDEA
 * FileNameComparator semantics. Repeated paths keep their input order; entries
 * without a path trail in input order. */
export function gitFileTreeOrder<T>(items: readonly T[], getPath: (item: T) => string): number[] {
  const entries = items.map((item, index) => ({ index, path: getPath(item) }));
  const placed = entries.filter((entry) => entry.path.trim().length > 0);
  const nodes = buildPathTree(placed, {
    getPath: (entry) => entry.path,
    getKey: (entry) => String(entry.index),
    compareNames: compareGitFileNames,
  });
  const order: number[] = [];
  const visit = (nodes: readonly PathTreeNode<(typeof placed)[number]>[]) => {
    for (const node of nodes) {
      if (node.type === "leaf") order.push(node.item.index);
      else visit(node.children);
    }
  };
  visit(nodes);
  for (const entry of entries) if (!entry.path.trim()) order.push(entry.index);
  return order;
}

/** Path the commit file tree uses for a diff (`gitDiffToCommitFile`). */
export function gitDiffDisplayPath(diff: GitDiff): string {
  return diff.new_path || diff.file_path || diff.old_path || "";
}

/** Commit diff collection in the same order as the Git Log commit files tree. */
export function orderGitDiffsForTree(diffs: readonly GitDiff[]): GitDiff[] {
  return gitFileTreeOrder(diffs, gitDiffDisplayPath).map((index) => diffs[index]);
}
