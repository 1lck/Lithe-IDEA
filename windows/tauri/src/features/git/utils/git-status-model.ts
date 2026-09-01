import {
  buildPathTree,
  type PathTreeNode,
} from "@/features/sidebar/lib/path-tree";
import type { GitFile } from "../types/git.types";

export type GitStatusGroup =
  "added" | "modified" | "deleted" | "renamed" | "untracked";

export const GIT_STATUS_ORDER: GitStatusGroup[] = [
  "added",
  "modified",
  "deleted",
  "renamed",
  "untracked",
];

export interface GitFolderState {
  descendantFilePaths: string[];
  areAllDescendantFilesStaged: boolean;
}

export interface GitFolderTree {
  nodes: PathTreeNode<GitFile>[];
  folderStateById: Map<string, GitFolderState>;
}

export interface GitStatusPresentation {
  stagedFiles: GitFile[];
  unstagedFiles: GitFile[];
  hasStagedDiffableFiles: boolean;
  hasUnstagedDiffableFiles: boolean;
  visibleFiles: GitFile[];
  displayFileByPath: Map<string, GitFile>;
  trackedFiles: GitFile[];
  untrackedFiles: GitFile[];
  groupedTrackedFiles: Record<GitStatusGroup, GitFile[]>;
  groupedUntrackedFiles: Record<GitStatusGroup, GitFile[]>;
}

export interface VisibleGitFiles {
  files: GitFile[];
  fileByPath: Map<string, GitFile>;
}

const createEmptyGitStatusGroups = (): Record<GitStatusGroup, GitFile[]> => ({
  added: [],
  modified: [],
  deleted: [],
  renamed: [],
  untracked: [],
});

function mergeWholePathStatus(existing: GitFile, incoming: GitFile): GitFile {
  const deleted = [existing, incoming].find(
    (file) => file.status === "deleted",
  );
  const recreated = [existing, incoming].find(
    (file) => file.status === "untracked",
  );
  if (deleted && recreated) {
    // Git reports an index deletion and a same-path untracked file separately.
    // Selected-path commit stages the current file, so present it as the
    // modified whole-path snapshot that the user will actually commit.
    return {
      ...deleted,
      status: "modified",
      staged: deleted.staged || recreated.staged,
      worktree: true,
    };
  }
  return !existing.staged && incoming.staged ? incoming : existing;
}

function coalesceWholePathStatuses(files: readonly GitFile[]): GitFile[] {
  const fileByPath = new Map<string, GitFile>();
  for (const file of files) {
    const existing = fileByPath.get(file.path);
    fileByPath.set(
      file.path,
      existing ? mergeWholePathStatus(existing, file) : file,
    );
  }
  return [...fileByPath.values()];
}

export function buildGitFolderTree(fileList: GitFile[]): GitFolderTree {
  const nodes = buildPathTree(fileList, {
    getKey: (file) =>
      `${file.path}:${file.staged ? "staged" : "unstaged"}:${file.status}`,
    getPath: (file) => file.path,
  });
  const folderStateById = new Map<string, GitFolderState>();

  const collectDescendantFiles = (node: PathTreeNode<GitFile>): GitFile[] => {
    if (node.type === "leaf") return [node.item];

    const descendantFiles = node.children.flatMap(collectDescendantFiles);
    folderStateById.set(node.id, {
      descendantFilePaths: descendantFiles.map((file) => file.path),
      areAllDescendantFilesStaged:
        descendantFiles.length > 0 &&
        descendantFiles.every((file) => file.staged),
    });
    return descendantFiles;
  };

  for (const node of nodes) collectDescendantFiles(node);
  return { nodes, folderStateById };
}

export function buildGitStatusPresentation(
  files: GitFile[],
): GitStatusPresentation {
  const stagedFiles: GitFile[] = [];
  const unstagedFiles: GitFile[] = [];
  const displayFileByPath = new Map<string, GitFile>();
  let hasStagedDiffableFiles = false;
  let hasUnstagedDiffableFiles = false;

  for (const file of files) {
    if (file.staged) {
      stagedFiles.push(file);
      hasStagedDiffableFiles = true;
    } else {
      unstagedFiles.push(file);
      hasUnstagedDiffableFiles = true;
    }

    const existingFile = displayFileByPath.get(file.path);
    displayFileByPath.set(
      file.path,
      existingFile ? mergeWholePathStatus(existingFile, file) : file,
    );
  }

  const visibleFiles = Array.from(displayFileByPath.values());
  const trackedFiles: GitFile[] = [];
  const untrackedFiles: GitFile[] = [];
  const groupedTrackedFiles = createEmptyGitStatusGroups();
  const groupedUntrackedFiles = createEmptyGitStatusGroups();

  for (const file of visibleFiles) {
    if (file.status === "untracked") {
      untrackedFiles.push(file);
      groupedUntrackedFiles.untracked.push(file);
    } else {
      trackedFiles.push(file);
      groupedTrackedFiles[file.status].push(file);
    }
  }

  return {
    stagedFiles,
    unstagedFiles,
    hasStagedDiffableFiles,
    hasUnstagedDiffableFiles,
    visibleFiles,
    displayFileByPath,
    trackedFiles,
    untrackedFiles,
    groupedTrackedFiles,
    groupedUntrackedFiles,
  };
}

export function buildVisibleGitFiles(
  files: readonly GitFile[],
  showUntrackedFiles: boolean,
): VisibleGitFiles {
  const visibleFiles: GitFile[] = [];
  const fileByPath = new Map<string, GitFile>();

  for (const file of coalesceWholePathStatuses(files)) {
    if (!showUntrackedFiles && file.status === "untracked") continue;
    visibleFiles.push(file);
    if (!fileByPath.has(file.path)) fileByPath.set(file.path, file);
  }

  return { files: visibleFiles, fileByPath };
}
