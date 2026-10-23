import type { GitFile } from "../types/git.types";
import { DEFAULT_CHANGELIST, fileChangelist, type LocalChangelists } from "./git-changelists";
import { gitFileTreeOrder } from "./git-file-tree-order";
import { buildGitStatusPresentation, orderedGitStatusFiles } from "./git-status-model";
import { getGitFileRepositoryPath } from "./git-status-selection";
import { isUntrackedDirectorySummary } from "./git-untracked-directories";

export interface GitStatusDisplayOrderOptions {
  repoPath?: string;
  changelists?: LocalChangelists;
  /** The Commit panel's `gitChangesFolderView` setting. */
  folderView: boolean;
}

/** Files in the order the Commit panel renders them: repository, changelist,
 * then the folder tree (`buildGitFolderTree` semantics) or IDEA status groups
 * (added, modified, deleted, renamed, untracked). Untracked directory summaries
 * and files without a repository are rows, not navigable diffs, and are
 * omitted. File navigation uses this order so arrows match the visible list. */
export function orderGitStatusFilesForDisplay(
  files: readonly GitFile[],
  { repoPath, changelists, folderView }: GitStatusDisplayOrderOptions,
): GitFile[] {
  const filesByRepository = new Map<string, GitFile[]>();
  for (const file of files) {
    const root = getGitFileRepositoryPath(file, repoPath);
    if (!root) continue;
    const repositoryFiles = filesByRepository.get(root) ?? [];
    repositoryFiles.push(file);
    filesByRepository.set(root, repositoryFiles);
  }

  const lists = changelists?.lists ?? [{ id: DEFAULT_CHANGELIST, name: "" }];
  const ordered: GitFile[] = [];
  for (const repositoryFiles of filesByRepository.values()) {
    for (const list of lists) {
      const listFiles = changelists
        ? repositoryFiles.filter((file) => fileChangelist(changelists, file, repoPath) === list.id)
        : repositoryFiles;
      if (folderView) {
        const diffable = listFiles.filter((file) => !isUntrackedDirectorySummary(file));
        for (const index of gitFileTreeOrder(
          diffable,
          (file) => file.repositoryRelativePath ?? file.path,
        )) ordered.push(diffable[index]);
      } else {
        const grouped = buildGitStatusPresentation(listFiles);
        const groups = { ...grouped.groupedTrackedFiles, untracked: grouped.untrackedFiles };
        for (const file of orderedGitStatusFiles(groups))
          if (!isUntrackedDirectorySummary(file)) ordered.push(file);
      }
    }
  }
  return ordered;
}
