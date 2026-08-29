import { useCallback, useState } from "react";
import { activateMainEditorPane } from "@/features/editor/stores/buffer-pane-sync";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { useTranslation } from "@/i18n/locale-provider";
import { showAlertDialog } from "@/ui/dialog";
import {
  getCommitDiff,
  getFileDiff,
  getReferenceWorkingTreeDiff,
  getRefDiff,
  getStashDiff,
} from "../api/git-diff-api";
import {
  loadWorkingTreeDiffsProgressively,
  type WorkingTreeDiffEntry,
  type WorkingTreeDiffScope,
} from "../services/working-tree-diff-loader";
import { loadWorkingTreeFileDiff } from "../services/working-tree-file-diff";
import type { MultiFileDiff } from "../types/git-diff.types";
import type { GitCommit, GitDiff, GitFile } from "../types/git.types";
import { countDiffStats } from "../utils/git-diff-helpers";
import { createSingleFileWorkingTreeDiff } from "../utils/working-tree-multi-diff";

const WORKING_TREE_TITLES: Record<WorkingTreeDiffScope, string> = {
  all: "git.diff.uncommitted",
  unstaged: "git.diff.unstagedChanges",
  staged: "git.diff.stagedChanges",
};

const WORKING_TREE_EMPTY_LABELS: Record<WorkingTreeDiffScope, string> = {
  all: "git.diff.emptyChanges",
  unstaged: "git.diff.emptyUnstagedChanges",
  staged: "git.diff.emptyStagedChanges",
};

function openDiffBuffer(
  virtualPath: string,
  displayName: string,
  diffData: GitDiff | MultiFileDiff,
) {
  activateMainEditorPane();
  return useBufferStore
    .getState()
    .actions.openBuffer(virtualPath, displayName, "", false, undefined, true, true, diffData);
}

function createMultiFileDiff({
  title,
  repoPath,
  commitHash,
  diffs,
  metadata,
}: {
  title?: string;
  repoPath: string;
  commitHash: string;
  diffs: GitDiff[];
  metadata?: Pick<
    MultiFileDiff,
    "commitMessage" | "commitDescription" | "commitAuthor" | "commitDate"
  >;
}): MultiFileDiff {
  const { additions, deletions } = countDiffStats(diffs);
  return {
    title,
    repoPath,
    commitHash,
    files: diffs,
    totalFiles: diffs.length,
    totalAdditions: additions,
    totalDeletions: deletions,
    ...metadata,
  };
}

function normalizeDisplayedFilePath(filePath: string, side: "old" | "new"): string {
  let actualFilePath = filePath;
  if (filePath.includes(" -> ")) {
    const [oldPath, newPath] = filePath.split(" -> ");
    actualFilePath = side === "new" ? newPath : oldPath;
  }

  const trimmed = actualFilePath.trim();
  return trimmed.startsWith('"') && trimmed.endsWith('"') ? trimmed.slice(1, -1) : trimmed;
}

export function useGitDiffActions({
  activeRepoPath,
  onFileSelect,
  gitFileByPath,
  workingTreeDiffEntriesByScope,
  commitByHash,
  currentBranch,
  onBranchDiffOpened,
}: {
  activeRepoPath: string | null;
  onFileSelect?: (path: string, isDir: boolean) => void;
  gitFileByPath: Map<string, GitFile>;
  workingTreeDiffEntriesByScope: Record<WorkingTreeDiffScope, WorkingTreeDiffEntry[]>;
  commitByHash: Map<string, GitCommit>;
  currentBranch?: string;
  onBranchDiffOpened?: () => void;
}) {
  const { t } = useTranslation();
  const [isLoadingCommitDiff, setIsLoadingCommitDiff] = useState(false);
  const [isLoadingBranchDiff, setIsLoadingBranchDiff] = useState(false);

  const openOriginalFile = useCallback(
    async (filePath: string) => {
      if (!activeRepoPath || !onFileSelect) return;

      try {
        const actualFilePath = normalizeDisplayedFilePath(filePath, "new");
        activateMainEditorPane();
        onFileSelect(`${activeRepoPath}/${actualFilePath}`, false);
      } catch (error) {
        console.error("Error opening file:", error);
        await showAlertDialog(
          t("git.diff.openFileFailed", { file: filePath, error: String(error) }),
          t("files.open"),
        );
      }
    },
    [activeRepoPath, onFileSelect, t],
  );

  const viewFileDiff = useCallback(
    async (filePath: string, staged = false) => {
      if (!activeRepoPath) return;

      try {
        const actualFilePath = normalizeDisplayedFilePath(filePath, staged ? "new" : "old");
        const file = gitFileByPath.get(actualFilePath);
        const diff = file
          ? await loadWorkingTreeFileDiff(activeRepoPath, { ...file, staged })
          : await getFileDiff(activeRepoPath, actualFilePath, staged);
        if (!diff || (diff.lines.length === 0 && !diff.is_image && !diff.is_binary)) {
          await openOriginalFile(actualFilePath);
          return;
        }

        const fileKey = `${staged ? "staged" : "unstaged"}:${actualFilePath}`;
        const selectedDiff = createSingleFileWorkingTreeDiff({
          repoPath: activeRepoPath,
          fileKey,
          diff,
          title: t(WORKING_TREE_TITLES.all),
        });

        openDiffBuffer("diff://working-tree/all-files", t(WORKING_TREE_TITLES.all), selectedDiff);
      } catch (error) {
        console.error("Error getting file diff:", error);
        await showAlertDialog(
          t("git.diff.getFileDiffFailed", { file: filePath, error: String(error) }),
          t("git.diff.title"),
        );
      }
    },
    [activeRepoPath, gitFileByPath, openOriginalFile, t],
  );

  const viewWorkingTreeDiff = useCallback(
    async (scope: WorkingTreeDiffScope = "all", filePaths?: string[]) => {
      if (!activeRepoPath) return;

      try {
        const selectedFilePaths = filePaths ? new Set(filePaths) : null;
        const diffEntries = selectedFilePaths
          ? workingTreeDiffEntriesByScope[scope].filter(([, file]) =>
              selectedFilePaths.has(file.path),
            )
          : workingTreeDiffEntriesByScope[scope];
        if (diffEntries.length === 0) {
          await showAlertDialog(t(WORKING_TREE_EMPTY_LABELS[scope]), t("git.diff.title"));
          return;
        }

        const title = t(WORKING_TREE_TITLES[scope]);
        const multiDiff: MultiFileDiff = {
          title,
          repoPath: activeRepoPath,
          commitHash: "working-tree",
          files: [],
          totalFiles: 0,
          totalAdditions: 0,
          totalDeletions: 0,
          fileKeys: [],
          isLoading: true,
          indexingProgress: {
            processed: 0,
            total: diffEntries.length,
            label: t("git.indexing"),
          },
        };
        const bufferId = openDiffBuffer(`diff://working-tree/${scope}`, title, multiDiff);

        void loadWorkingTreeDiffsProgressively({
          repoPath: activeRepoPath,
          bufferId,
          title,
          indexingLabel: t("git.indexing"),
          diffEntries,
        });
      } catch (error) {
        console.error("Error getting working tree diff:", error);
        await showAlertDialog(
          t("git.diff.getWorkingTreeDiffFailed", { error: String(error) }),
          t("git.diff.title"),
        );
      }
    },
    [activeRepoPath, t, workingTreeDiffEntriesByScope],
  );

  const viewCommitDiff = useCallback(
    async (commitHash: string, filePath?: string) => {
      if (!activeRepoPath) return;

      setIsLoadingCommitDiff(true);
      try {
        const diffs = await getCommitDiff(activeRepoPath, commitHash);
        if (!diffs?.length) {
          await showAlertDialog(
            filePath
              ? t("git.diff.noChangesInCommitForFile", { file: filePath })
              : t("git.diff.noChangesInCommit"),
            t("git.diff.title"),
          );
          return;
        }

        if (filePath) {
          const diff = diffs.find((item) => item.file_path === filePath) ?? diffs[0];
          const diffFileName = `${diff.file_path.split("/").pop()}.diff`;
          openDiffBuffer(`diff://commit/${commitHash}/${diffFileName}`, diffFileName, diff);
          return;
        }

        const commit = commitByHash.get(commitHash);
        const title = `Commit ${commitHash.substring(0, 7)}`;
        const multiDiff = createMultiFileDiff({
          title,
          repoPath: activeRepoPath,
          commitHash,
          diffs,
          metadata: {
            commitMessage: commit?.message,
            commitDescription: commit?.description,
            commitAuthor: commit?.author,
            commitDate: commit?.date,
          },
        });
        openDiffBuffer(
          `diff://commit/${commitHash}/all-files`,
          `${title} (${diffs.length} files)`,
          multiDiff,
        );
      } catch (error) {
        console.error("Error getting commit diff:", error);
        await showAlertDialog(
          t("git.diff.getCommitDiffFailed", { commit: commitHash, error: String(error) }),
          t("git.diff.title"),
        );
      } finally {
        setIsLoadingCommitDiff(false);
      }
    },
    [activeRepoPath, commitByHash, t],
  );

  const viewStashDiff = useCallback(
    async (stashIndex: number) => {
      if (!activeRepoPath) return;

      try {
        const diffs = await getStashDiff(activeRepoPath, stashIndex);
        if (!diffs?.length) {
          await showAlertDialog(t("git.diff.noChangesInStash"), t("git.diff.title"));
          return;
        }

        const commitHash = `stash@{${stashIndex}}`;
        const multiDiff = createMultiFileDiff({
          repoPath: activeRepoPath,
          commitHash,
          diffs,
        });
        openDiffBuffer(
          `diff://stash/${stashIndex}/all-files`,
          `Stash @{${stashIndex}} (${diffs.length} files)`,
          multiDiff,
        );
      } catch (error) {
        console.error("Error getting stash diff:", error);
        await showAlertDialog(
          t("git.diff.getStashDiffFailed", {
            stash: `stash@{${stashIndex}}`,
            error: String(error),
          }),
          t("git.diff.title"),
        );
      }
    },
    [activeRepoPath, t],
  );

  const viewTagComparison = useCallback(
    async (baseRef: string, targetRef: string, title: string) => {
      if (!activeRepoPath) return;

      try {
        const diffs = await getRefDiff(activeRepoPath, baseRef, targetRef);
        if (!diffs?.length) {
          await showAlertDialog(
            t("git.diff.noChangesBetween", { base: baseRef, target: targetRef }),
            t("git.diff.title"),
          );
          return;
        }

        const multiDiff = createMultiFileDiff({
          title,
          repoPath: activeRepoPath,
          commitHash: `${baseRef}..${targetRef}`,
          diffs,
        });
        openDiffBuffer(
          `diff://tag/${encodeURIComponent(title)}/all-files`,
          `${title} (${diffs.length} files)`,
          multiDiff,
        );
      } catch (error) {
        console.error("Error getting tag comparison:", error);
        await showAlertDialog(
          t("git.diff.compareRefsFailed", {
            base: baseRef,
            target: targetRef,
            error: String(error),
          }),
          t("git.diff.title"),
        );
      }
    },
    [activeRepoPath, t],
  );

  const viewBranchDiff = useCallback(
    async (baseBranch: string) => {
      const targetBranch = currentBranch ?? "HEAD";
      if (!activeRepoPath || !baseBranch || baseBranch === targetBranch) return;

      const title = `${baseBranch}..${targetBranch}`;
      setIsLoadingBranchDiff(true);
      try {
        const diffs = await getRefDiff(activeRepoPath, baseBranch, targetBranch);
        if (!diffs?.length) {
          await showAlertDialog(
            `No changes between ${baseBranch} and ${targetBranch}.`,
            "Git Diff",
          );
          return;
        }

        const multiDiff = createMultiFileDiff({
          title,
          repoPath: activeRepoPath,
          commitHash: title,
          diffs,
        });
        openDiffBuffer(
          `diff://branch/${encodeURIComponent(title)}/all-files`,
          `${title} (${diffs.length} files)`,
          multiDiff,
        );
        onBranchDiffOpened?.();
      } catch (error) {
        console.error("Error getting branch comparison:", error);
        await showAlertDialog(
          `Failed to compare ${baseBranch} and ${targetBranch}:\n${error}`,
          "Git Diff",
        );
      } finally {
        setIsLoadingBranchDiff(false);
      }
    },
    [activeRepoPath, currentBranch, onBranchDiffOpened],
  );

  const viewReferenceWorkingTreeDiff = useCallback(
    async (reference: string) => {
      if (!activeRepoPath) return;
      const title = `${reference}..WORKTREE`;
      setIsLoadingBranchDiff(true);
      try {
        const diffs = await getReferenceWorkingTreeDiff(activeRepoPath, reference);
        if (!diffs?.length) {
          await showAlertDialog(
            t("git.diff.noChangesBetween", { base: reference, target: "WORKTREE" }),
            t("git.diff.title"),
          );
          return;
        }
        openDiffBuffer(
          `diff://reference/${encodeURIComponent(reference)}/working-tree`,
          `${title} (${diffs.length} files)`,
          createMultiFileDiff({
            title,
            repoPath: activeRepoPath,
            commitHash: title,
            diffs,
          }),
        );
      } catch (error) {
        await showAlertDialog(
          t("git.diff.getWorkingTreeDiffFailed", { error: String(error) }),
          t("git.diff.title"),
        );
      } finally {
        setIsLoadingBranchDiff(false);
      }
    },
    [activeRepoPath, t],
  );

  return {
    isLoadingCommitDiff,
    isLoadingBranchDiff,
    openOriginalFile,
    viewFileDiff,
    viewWorkingTreeDiff,
    viewCommitDiff,
    viewStashDiff,
    viewTagComparison,
    viewBranchDiff,
    viewReferenceWorkingTreeDiff,
  };
}
