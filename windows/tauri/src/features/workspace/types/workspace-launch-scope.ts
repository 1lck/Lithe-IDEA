import { normalizePath, stripTrailingPathSeparators } from "@/utils/path-helpers";

export interface WorkspaceLaunchScope {
  workspaceId: string;
  root: string;
}

function workspaceRootKey(root: string): string {
  const normalized = normalizePath(stripTrailingPathSeparators(root));
  return /^(?:[A-Za-z]:\/|\/\/)/.test(normalized) ? normalized.toLowerCase() : normalized;
}

export function workspaceScopeMatchesRoot(
  scope: WorkspaceLaunchScope,
  root: string | null | undefined,
): boolean {
  if (!root) return false;
  return workspaceRootKey(root) === workspaceRootKey(scope.root);
}

export function workspaceScopesMatch(
  left: WorkspaceLaunchScope,
  right: WorkspaceLaunchScope,
): boolean {
  return left.workspaceId === right.workspaceId && workspaceScopeMatchesRoot(left, right.root);
}
