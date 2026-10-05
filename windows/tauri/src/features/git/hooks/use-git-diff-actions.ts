import { useCallback, useEffect, useRef, useState } from "react";
import { activateMainEditorPane } from "@/features/editor/stores/buffer-pane-sync";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { useTranslation } from "@/i18n/locale-provider";
import { showAlertDialog } from "@/ui/dialog";
import { resolveRepositoryForFile } from "../api/git-repo-api";
import { withCommitDescription } from "../api/git-commits-api";
import {
  getCommitDiff,
  getFullContextFileDiff,
  getRefDiff,
  getStashDiff,
  getTypedReferenceDiff,
  getWorkingTreePathDiff,
  getWorkingTreeRefDiff,
} from "../api/git-diff-api";
import {
  loadWorkingTreeDiffsProgressively,
  type WorkingTreeDiffEntry,
  type WorkingTreeDiffScope,
} from "../services/working-tree-diff-loader";
import type { MultiFileDiff } from "../types/git-diff.types";
import type { GitCommit, GitDiff, GitFile, GitReference } from "../types/git.types";
import { mapGitReadsInBatches } from "../utils/git-async-batch";
import { aggregateSelectedCommitDiffs } from "../utils/git-commit-selection-diff";
import {
  getGitFileOriginalRepositoryRelativePath,
  getGitFileRepositoryPath,
  getGitFileRepositoryRelativePath,
} from "../utils/git-status-selection";
import { createRequestGeneration, type RequestGeneration } from "../utils/request-generation";
import { createCommitDiffBuffer, createMultiFileDiff } from "../utils/multi-file-diff";
import { createSingleFileWorkingTreeDiff, createCommitWorkingTreeFileOrder } from "../utils/working-tree-multi-diff";

import { useCommitFilePreview } from "./use-commit-file-preview";

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
  currentReference,
  onBranchDiffOpened,
  commitPreviewScope = null,
}: {
  activeRepoPath: string | null;
  onFileSelect?: (path: string, isDir: boolean) => void;
  gitFileByPath: Map<string, GitFile>;
  workingTreeDiffEntriesByScope: Record<WorkingTreeDiffScope, WorkingTreeDiffEntry[]>;
  commitByHash: Map<string, GitCommit>;
  currentBranch?: string;
  currentReference?: GitReference;
  onBranchDiffOpened?: () => void;
  commitPreviewScope?: string | null;
}) {
  const { t } = useTranslation();
  const [isLoadingCommitDiff, setIsLoadingCommitDiff] = useState(false);
  const [isLoadingBranchDiff, setIsLoadingBranchDiff] = useState(false);
  const latestFileDiffRequestRef = useRef<RequestGeneration | null>(null);
  const latestFileDiffRequest =
    typeof latestFileDiffRequestRef.current?.begin === "function"
      ? latestFileDiffRequestRef.current
      : createRequestGeneration();
  latestFileDiffRequestRef.current = latestFileDiffRequest;
  const commitDiffRequests = useRef(createRequestGeneration()).current;
  useEffect(() => {
    setIsLoadingCommitDiff(false);
    // Invalidate on repository changes (including A -> B -> A) and unmount.
    return () => {
      commitDiffRequests.begin();
    };
  }, [activeRepoPath, commitDiffRequests]);
  const activeRepoPathRef = useRef(activeRepoPath);
  activeRepoPathRef.current = activeRepoPath;
  const previewCommitFileDiff = useCommitFilePreview(
    activeRepoPath,
    commitPreviewScope,
    openDiffBuffer,
  );

  const openOriginalFile = useCallback(
    async (filePath: string) => {
      if (!activeRepoPath || !onFileSelect) return;

      try {
        const actualFilePath = normalizeDisplayedFilePath(filePath, "new");
        const file = gitFileByPath.get(actualFilePath);
        const fileRepoPath = file ? getGitFileRepositoryPath(file, activeRepoPath) : activeRepoPath;
        const relativePath = file ? getGitFileRepositoryRelativePath(file) : actualFilePath;
        activateMainEditorPane();
        onFileSelect(`${fileRepoPath}/${relativePath}`, false);
      } catch (error) {
        console.error("Error opening file:", error);
        await showAlertDialog(
          t("git.diff.openFileFailed", {
            file: filePath,
            error: String(error),
          }),
          t("files.open"),
        );
      }
    },
    [activeRepoPath, gitFileByPath, onFileSelect, t],
  );

  const viewFileDiff = useCallback(
    async (filePath: string, staged = false) => {
      if (!activeRepoPath) return;
      const requestId = latestFileDiffRequest.begin();

      try {
        const actualFilePath = normalizeDisplayedFilePath(filePath, staged ? "new" : "old");
        const file = gitFileByPath.get(actualFilePath);
        const workingTreeFileOrder = createCommitWorkingTreeFileOrder(activeRepoPath,
          workingTreeDiffEntriesByScope.all.length
            ? workingTreeDiffEntriesByScope.all.map(([, file]) => file)
            : [...gitFileByPath.values()], staged);
        if (file) {
          const fileKey = `${staged ? "staged" : "unstaged"}:${actualFilePath}`;
          const fileRepoPath = getGitFileRepositoryPath(file, activeRepoPath) ?? activeRepoPath;
          const relativePath = getGitFileRepositoryRelativePath(file);
          const originalRelativePath = getGitFileOriginalRepositoryRelativePath(file);
          const title = t(staged ? WORKING_TREE_TITLES.staged : WORKING_TREE_TITLES.all);
          const untracked = file.status === "untracked";
          const workingTreeTargets: MultiFileDiff["workingTreeTargets"] = {
            [fileKey]: {
              repoPath: fileRepoPath,
              filePath: relativePath,
              ...(originalRelativePath ? { originalPath: originalRelativePath } : {}),
              untracked,
              ...(staged ? { staged: true } : {}),
              ...(!staged && file.staged ? { hasStagedChanges: true } : {}),
            },
          };
          const loadingDiff: MultiFileDiff = {
            title,
            repoPath: fileRepoPath,
            commitHash: "working-tree",
            files: [],
            totalFiles: 0,
            totalAdditions: 0,
            totalDeletions: 0,
            fileKeys: [],
            initiallyExpandedFileKey: fileKey,
            workingTreeTargets,
            commitPreview: true,
            workingTreeFileOrder,
            isLoading: true,
            indexingProgress: {
              processed: 0,
              total: 1,
              label: t("git.indexing"),
            },
          };
          const bufferId = openDiffBuffer("diff://working-tree/all-files", title, loadingDiff);
          void (async () => {
            const diff = staged
              ? await getFullContextFileDiff(fileRepoPath, relativePath, true)
              : await getWorkingTreePathDiff(
                  fileRepoPath,
                  relativePath,
                  untracked,
                  originalRelativePath,
                  true,
                );
            if (
              !latestFileDiffRequest.isCurrent(requestId) ||
              activeRepoPathRef.current !== activeRepoPath
            ) {
              return;
            }
            await loadWorkingTreeDiffsProgressively({
              repoPath: fileRepoPath,
              bufferId,
              title,
              indexingLabel: t("git.indexing"),
              diffEntries: [],
              initialDiffs:
                diff && (diff.lines.length > 0 || diff.is_image || diff.is_binary)
                  ? [{ fileKey, diff }]
                  : [],
              initialProcessed: 1,
              initiallyExpandedFileKey: fileKey,
              workingTreeTargets,
              commitPreview: true,
              workingTreeFileOrder,
            });
          })();
          return;
        }

        // A status refresh may temporarily remove the displayed file mapping.
        // Resolve its real owner rather than opening a preview without write identity.
        const resolved = await resolveRepositoryForFile(activeRepoPath, actualFilePath);
        if (!latestFileDiffRequest.isCurrent(requestId)
          || activeRepoPathRef.current !== activeRepoPath) return;
        if (!resolved) { await openOriginalFile(actualFilePath); return; }
        const diff = staged
          ? await getFullContextFileDiff(resolved.repoPath, resolved.filePath, true)
          : await getWorkingTreePathDiff(resolved.repoPath, resolved.filePath, false, undefined, true);
        if (
          !latestFileDiffRequest.isCurrent(requestId) ||
          activeRepoPathRef.current !== activeRepoPath
        ) {
          return;
        }
        if (!diff || (diff.lines.length === 0 && !diff.is_image && !diff.is_binary)) {
          await openOriginalFile(actualFilePath);
          return;
        }

        const fileKey = `${staged ? "staged" : "unstaged"}:${actualFilePath}`;
        const selectedDiff = createSingleFileWorkingTreeDiff({
          repoPath: resolved.repoPath,
          fileKey,
          diff,
          title: t(WORKING_TREE_TITLES.all),
          target: { repoPath: resolved.repoPath, filePath: resolved.filePath,
            untracked: diff.is_new, ...(staged ? { staged: true } : {}) },
          commitPreview: true,
          workingTreeFileOrder,
        });

        openDiffBuffer("diff://working-tree/all-files", t(WORKING_TREE_TITLES.all), selectedDiff);
      } catch (error) {
        if (
          !latestFileDiffRequest.isCurrent(requestId) ||
          activeRepoPathRef.current !== activeRepoPath
        ) {
          return;
        }
        console.error("Error getting file diff:", error);
        await showAlertDialog(
          t("git.diff.getFileDiffFailed", {
            file: filePath,
            error: String(error),
          }),
          t("git.diff.title"),
        );
      }
    },
    [activeRepoPath, gitFileByPath, workingTreeDiffEntriesByScope, latestFileDiffRequest, openOriginalFile, t],
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
          wholePathSnapshot: scope === "all",
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

      const request = commitDiffRequests.begin();
      const isCurrent = () =>
        commitDiffRequests.isCurrent(request) && activeRepoPathRef.current === activeRepoPath;
      setIsLoadingCommitDiff(true);
      try {
        const diffs = await getCommitDiff(activeRepoPath, commitHash);
        if (!isCurrent()) return;
        if (!diffs?.length) {
          await showAlertDialog(
            filePath
              ? t("git.diff.noChangesInCommitForFile", { file: filePath })
              : t("git.diff.noChangesInCommit"),
            t("git.diff.title"),
          );
          return;
        }

        const listedCommit = commitByHash.get(commitHash);
        const commit = listedCommit
          ? await withCommitDescription(activeRepoPath, listedCommit)
          : undefined;
        if (!isCurrent()) return;
        const buffer = createCommitDiffBuffer({
          repoPath: activeRepoPath,
          commitHash,
          diffs,
          commit,
          initialFilePath: filePath,
        });
        openDiffBuffer(buffer.virtualPath, buffer.displayName, buffer.diffData);
      } catch (error) {
        if (!isCurrent()) return;
        console.error("Error getting commit diff:", error);
        await showAlertDialog(
          t("git.diff.getCommitDiffFailed", {
            commit: commitHash,
            error: String(error),
          }),
          t("git.diff.title"),
        );
      } finally {
        if (isCurrent()) setIsLoadingCommitDiff(false);
      }
    },
    [activeRepoPath, commitByHash, commitDiffRequests, t],
  );

  const viewCommitRangeDiff = useCallback(
    async (
      baseRef: string | null,
      targetRef: string,
      oldestLabel: string,
      newestLabel: string,
      filePath?: string,
    ) => {
      if (!activeRepoPath) return;

      setIsLoadingCommitDiff(true);
      try {
        const diffs = await getRefDiff(activeRepoPath, baseRef, targetRef);
        if (!diffs?.length) {
          await showAlertDialog(
            t("git.diff.noChangesBetween", {
              base: oldestLabel,
              target: newestLabel,
            }),
            t("git.diff.title"),
          );
          return;
        }

        const title = t("git.diff.commitRangeTitle", {
          base: oldestLabel,
          target: newestLabel,
        });
        const diffData = createMultiFileDiff({
          title,
          repoPath: activeRepoPath,
          commitHash: `${baseRef ?? "root"}..${targetRef}`,
          diffs,
          initialFilePath: filePath,
        });
        openDiffBuffer(
          `diff://commit-range/${encodeURIComponent(baseRef ?? "root")}..${encodeURIComponent(targetRef)}`,
          `${title} (${diffs.length} files)`,
          diffData,
        );
      } catch (error) {
        console.error("Error getting commit range diff:", error);
        await showAlertDialog(
          t("git.diff.compareRefsFailed", {
            base: oldestLabel,
            target: newestLabel,
            error: String(error),
          }),
          t("git.diff.title"),
        );
      } finally {
        setIsLoadingCommitDiff(false);
      }
    },
    [activeRepoPath, t],
  );

  const viewCommitSelectionDiff = useCallback(
    async (commits: readonly GitCommit[], filePath?: string) => {
      if (!activeRepoPath || commits.length === 0) return;
      setIsLoadingCommitDiff(true);
      try {
        const results = await mapGitReadsInBatches(commits, async (commit) => ({
          commit,
          diffs: await getCommitDiff(activeRepoPath, commit.hash),
        }));
        if (results.some((result) => result.diffs === null)) {
          throw new Error(t("git.log.unableToLoadFiles"));
        }
        const aggregate = aggregateSelectedCommitDiffs(
          results.map((result) => ({
            commit: result.commit,
            diffs: result.diffs ?? [],
          })),
        );
        if (aggregate.diffs.length === 0) {
          await showAlertDialog(t("git.diff.noChangesInSelectedCommits"), t("git.diff.title"));
          return;
        }

        const title = t("git.diff.selectedCommitsTitle", {
          count: commits.length,
        });
        const selectionKey = commits.map((commit) => commit.hash).join(",");
        const diffData = createMultiFileDiff({
          title,
          repoPath: activeRepoPath,
          commitHash: commits[0]?.hash ?? "selection",
          diffs: aggregate.diffs,
          initialFilePath: filePath,
          fileKeys: aggregate.fileKeys,
          fileLabels: aggregate.fileLabels,
        });
        diffData.totalFiles = aggregate.files.length;
        openDiffBuffer(
          `diff://commit-selection/${encodeURIComponent(selectionKey)}/all-files`,
          `${title} (${aggregate.files.length} files)`,
          diffData,
        );
      } catch (error) {
        console.error("Error getting selected commit diffs:", error);
        await showAlertDialog(
          t("git.diff.getSelectedCommitDiffFailed", { error: String(error) }),
          t("git.diff.title"),
        );
      } finally {
        setIsLoadingCommitDiff(false);
      }
    },
    [activeRepoPath, t],
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
            t("git.diff.noChangesBetween", {
              base: baseRef,
              target: targetRef,
            }),
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
    async (baseBranch: GitReference | string) => {
      const targetBranch = currentBranch ?? "HEAD";
      const baseName = typeof baseBranch === "string" ? baseBranch : baseBranch.fullName;
      if (!activeRepoPath || !baseName || baseName === targetBranch) return;

      const title = `${baseName}..${targetBranch}`;
      setIsLoadingBranchDiff(true);
      try {
        const diffs =
          typeof baseBranch !== "string" && currentReference
            ? await getTypedReferenceDiff(activeRepoPath, baseBranch, currentReference)
            : await getRefDiff(activeRepoPath, baseName, targetBranch);
        if (!diffs?.length) {
          await showAlertDialog(
            t("git.diff.noChangesBetween", { base: baseName, target: targetBranch }),
            t("git.diff.title"),
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
          t("git.diff.compareRefsFailed", {
            base: baseName,
            target: targetBranch,
            error: String(error),
          }),
          t("git.diff.title"),
        );
      } finally {
        setIsLoadingBranchDiff(false);
      }
    },
    [activeRepoPath, currentBranch, currentReference, onBranchDiffOpened, t],
  );

  const viewReferenceWorkingTreeDiff = useCallback(
    async (reference: GitReference | string, displayName: string) => {
      if (!activeRepoPath) return;
      setIsLoadingBranchDiff(true);
      try {
        const diffs = await getWorkingTreeRefDiff(activeRepoPath, reference);
        if (!diffs?.length) {
          await showAlertDialog(
            t("git.log.noWorkingTreeDifferences", { branch: displayName }),
            t("git.diff.title"),
          );
          return;
        }
        const fullName = typeof reference === "string" ? reference : reference.fullName;
        const title = t("git.log.workingTreeComparisonTitle", {
          branch: displayName,
        });
        openDiffBuffer(
          `diff://working-tree-ref/${encodeURIComponent(fullName)}/all-files`,
          `${title} (${diffs.length} files)`,
          createMultiFileDiff({
            title,
            repoPath: activeRepoPath,
            commitHash: `${fullName}..working-tree`,
            diffs,
          }),
        );
      } catch (error) {
        console.error("Error comparing reference with the working tree:", error);
        await showAlertDialog(
          t("git.log.workingTreeComparisonFailed", {
            branch: displayName,
            error: String(error),
          }),
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
    previewCommitFileDiff,
    viewCommitRangeDiff,
    viewCommitSelectionDiff,
    viewStashDiff,
    viewTagComparison,
    viewBranchDiff,
    viewReferenceWorkingTreeDiff,
  };
}
