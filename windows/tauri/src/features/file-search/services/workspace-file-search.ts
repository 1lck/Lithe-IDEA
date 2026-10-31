import { fffEnsureWorkspaces } from "../lib/file-search-api";
import { canUseNativeFileSearch } from "../utils/file-search-paths";

export const ensureWorkspaceFileSearch = async (
  rootPaths: readonly string[],
  workspaceId?: string,
): Promise<string[]> => {
  const nativeRootPaths = Array.from(new Set(rootPaths.filter(canUseNativeFileSearch)));
  if (nativeRootPaths.length === 0) return [];

  await fffEnsureWorkspaces(nativeRootPaths, workspaceId);
  return nativeRootPaths;
};
