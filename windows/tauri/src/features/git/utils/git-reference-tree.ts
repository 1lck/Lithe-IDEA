import { useEffect, useState } from "react";
import { invoke } from "@/platform/tauri-core";
import type { GitReference, GitReferenceKind } from "../types/git.types";

export interface GitReferenceTreeNode {
  id: string;
  name: string;
  path: string;
  reference?: GitReference;
  children: GitReferenceTreeNode[];
}

export function countGitReferencesByKind(
  references: GitReference[],
  kind: GitReferenceKind,
): number {
  return references.filter((reference) => reference.kind === kind).length;
}

/**
 * Returns the references shown by the Git Log's "my branches" view.
 *
 * Marked local branches are the user's explicit branch set. The checked-out
 * branch and its configured remote are also retained so the shortcut remains
 * useful immediately after opening a repository, before anything is marked.
 */
export function filterGitLogReferences(
  references: GitReference[],
  markedReferenceFullNames: ReadonlySet<string>,
  showMyBranchesOnly: boolean,
  selectedReferenceFullName?: string,
): GitReference[] {
  if (!showMyBranchesOnly) return references;

  const current = references.find((reference) => reference.isCurrent);
  const selected = selectedReferenceFullName
    ? references.find((reference) => reference.fullName === selectedReferenceFullName)
    : undefined;
  const visibleNames = new Set(
    references
      .filter(
        (reference) =>
          reference.kind === "local" &&
          (markedReferenceFullNames.has(reference.fullName) || reference.isCurrent),
      )
      .map((reference) => reference.fullName),
  );

  if (current?.upstreamShortName) {
    const upstream = references.find(
      (reference) =>
        reference.kind === "remote" && reference.shortName === current.upstreamShortName,
    );
    if (upstream) visibleNames.add(upstream.fullName);
  }
  if (selected) visibleNames.add(selected.fullName);

  return references.filter((reference) => visibleNames.has(reference.fullName));
}

export function collectGitReferenceGroupIds(nodes: GitReferenceTreeNode[]): string[] {
  return nodes.flatMap((node) => [
    ...(node.children.length > 0 ? [node.id] : []),
    ...collectGitReferenceGroupIds(node.children),
  ]);
}

/** One node of the tree `git.referenceTree` returns; `reference` indexes the request. */
interface CoreReferenceTreeNode {
  name: string;
  path: string;
  reference: number | null;
  children: CoreReferenceTreeNode[];
}

/**
 * Asks Core to group and order the references of one kind (`git.referenceTree`).
 *
 * Core owns the `/` grouping and the sibling order; this only attaches the
 * loaded references and the view's row identities to the planned nodes.
 */
export async function loadGitReferenceTree(
  references: readonly GitReference[],
  kind: GitReferenceKind,
  markedReferenceFullNames: ReadonlySet<string> = new Set(),
  idPrefix = "",
): Promise<GitReferenceTreeNode[]> {
  const ofKind = references.filter((item) => item.kind === kind);
  if (ofKind.length === 0) return [];
  const plan = await invoke<{ nodes: CoreReferenceTreeNode[] }>("git.referenceTree", {
    references: ofKind.map((item) => ({
      name: item.shortName,
      ...(markedReferenceFullNames.has(item.fullName) ? { prioritized: true } : {}),
    })),
  });
  const attach = (node: CoreReferenceTreeNode): GitReferenceTreeNode => {
    const reference = node.reference === null ? undefined : ofKind[node.reference];
    if (node.reference !== null && !reference) throw new Error("Invalid Git reference tree plan");
    return {
      id: `${idPrefix}${kind}:${node.path}`,
      name: node.name,
      path: node.path,
      ...(reference ? { reference } : {}),
      children: node.children.map(attach),
    };
  };
  return plan.nodes.map(attach);
}

export interface GitReferenceTreeSource {
  key: string;
  references: readonly GitReference[];
  kind: GitReferenceKind;
  marked?: ReadonlySet<string>;
  idPrefix?: string;
}

/**
 * Trees for several sources, planned by Core outside rendering. `null` until the
 * latest sources resolve; stale results are discarded.
 */
export function useGitReferenceTrees(
  sources: readonly GitReferenceTreeSource[],
): ReadonlyMap<string, GitReferenceTreeNode[]> | null {
  const [snapshot, setSnapshot] = useState<{
    sources: readonly GitReferenceTreeSource[];
    trees: Map<string, GitReferenceTreeNode[]>;
  } | null>(null);
  useEffect(() => {
    let current = true;
    void Promise.all(
      sources.map(async (source) => [
        source.key,
        await loadGitReferenceTree(
          source.references,
          source.kind,
          source.marked,
          source.idPrefix,
        ),
      ] as const),
    )
      .then((entries) => {
        if (current) setSnapshot({ sources, trees: new Map(entries) });
      })
      .catch((error) => {
        if (current) console.error("Failed to plan Git reference trees:", error);
      });
    return () => {
      current = false;
    };
  }, [sources]);
  return snapshot?.sources === sources ? snapshot.trees : null;
}

/**
 * `refs/remotes/<remote>/HEAD` is a symbolic alias for the remote's default
 * branch, not a distinct branch a user can check out or diff; listing it next
 * to the real branches is noise (selecting it also cannot resolve to a commit
 * of its own). It is therefore hidden from the reference tree.
 */
export function isRemoteSymbolicHeadReference(reference: GitReference): boolean {
  return (
    reference.kind === "remote" &&
    (reference.shortName.endsWith("/HEAD") || reference.fullName.endsWith("/HEAD"))
  );
}

/** References the tree renders, excluding remote symbolic HEAD aliases. */
export function filterSelectableGitReferences(references: GitReference[]): GitReference[] {
  return references.filter((reference) => !isRemoteSymbolicHeadReference(reference));
}
