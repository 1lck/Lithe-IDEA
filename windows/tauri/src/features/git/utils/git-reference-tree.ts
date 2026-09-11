import type { GitReference, GitReferenceKind } from "../types/git.types";

export interface GitReferenceTreeNode {
  id: string;
  name: string;
  path: string;
  reference?: GitReference;
  children: GitReferenceTreeNode[];
}

interface MutableReferenceNode extends GitReferenceTreeNode {
  children: MutableReferenceNode[];
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

export function buildGitReferenceTree(
  references: GitReference[],
  kind: GitReferenceKind,
  markedReferenceFullNames: ReadonlySet<string> = new Set(),
): GitReferenceTreeNode[] {
  const roots: MutableReferenceNode[] = [];

  for (const reference of references.filter((item) => item.kind === kind)) {
    const parts = reference.shortName.split("/").filter(Boolean);
    let siblings = roots;
    let path = "";

    parts.forEach((part, index) => {
      path = path ? `${path}/${part}` : part;
      let node = siblings.find((candidate) => candidate.name === part);
      if (!node) {
        node = { id: `${kind}:${path}`, name: part, path, children: [] };
        siblings.push(node);
      }
      if (index === parts.length - 1) node.reference = reference;
      siblings = node.children;
    });
  }

  const containsMarkedReference = (node: MutableReferenceNode): boolean =>
    Boolean(node.reference && markedReferenceFullNames.has(node.reference.fullName)) ||
    node.children.some(containsMarkedReference);

  const sortNodes = (nodes: MutableReferenceNode[]) => {
    nodes.sort((left, right) => {
      const leftIsMarked = Boolean(
        left.reference && markedReferenceFullNames.has(left.reference.fullName),
      );
      const rightIsMarked = Boolean(
        right.reference && markedReferenceFullNames.has(right.reference.fullName),
      );
      if (leftIsMarked !== rightIsMarked) return leftIsMarked ? -1 : 1;

      const leftContainsMarked = containsMarkedReference(left);
      const rightContainsMarked = containsMarkedReference(right);
      if (leftContainsMarked !== rightContainsMarked) return leftContainsMarked ? -1 : 1;

      if (Boolean(left.children.length) !== Boolean(right.children.length)) {
        return left.children.length ? -1 : 1;
      }
      return left.name.localeCompare(right.name);
    });
    nodes.forEach((node) => sortNodes(node.children));
  };
  sortNodes(roots);
  return roots;
}
