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

export function buildGitReferenceTree(
  references: GitReference[],
  kind: GitReferenceKind,
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

  const sortNodes = (nodes: MutableReferenceNode[]) => {
    nodes.sort((left, right) => {
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
