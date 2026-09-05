import { open } from "@tauri-apps/plugin-dialog";
import type { MouseEvent as ReactMouseEvent } from "react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { toast } from "sonner";
import { Button } from "@/ui/button";
import { showConfirmDialog, showPromptDialog } from "@/ui/dialog";
import { Dropdown, useDropdownMenu } from "@/ui/dropdown";
import { ResizableHandle, ResizablePanel, ResizablePanelGroup } from "@/ui/resizable";
import { tryWriteClipboardText } from "@/utils/clipboard";
import { useTranslation } from "@/i18n/locale-provider";
import { useProjectStore } from "@/features/window/stores/project.store";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { useGitLogController } from "../../hooks/use-git-log-controller";
import { useGitDiffActions } from "../../hooks/use-git-diff-actions";
import {
  checkoutGitReference,
  createAndCheckoutBranch,
  deleteBranch,
  renameBranch,
  setBranchUpstream,
  unsetBranchUpstream,
} from "../../api/git-branches-api";
import {
  checkoutAndRebase,
  mergeBranch,
  pullRemoteReference,
  rebaseOntoBranch,
  type IntegrationOutcome,
} from "../../api/git-integration-api";
import { deleteRemoteBranch } from "../../api/git-remotes-api";
import { addWorktreeFromReference } from "../../api/git-worktrees-api";
import { useGitLogPreferencesStore } from "../../stores/git-log-preferences.store";
import { useRepositoryStore } from "../../stores/git-repository.store";
import type { GitCommit, GitFile, GitReference } from "../../types/git.types";
import { useGitHistoryMutations } from "../../hooks/use-git-history-mutations";
import { useGitPullWorkflow } from "../../hooks/use-git-pull-workflow";
import {
  resolveGitHistoryContextSelection,
  selectedCommitsInHistoryOrder,
  updateGitHistorySelection,
} from "../../utils/git-history-selection";
import {
  suggestWorktreeBranchName,
  type GitReferenceAction,
} from "../../utils/git-reference-actions";
import { showGitPushDialog } from "../../services/git-push-dialog-service";
import type {
  WorkingTreeDiffEntry,
  WorkingTreeDiffScope,
} from "../../services/working-tree-diff-loader";
import { GitCommitInspector } from "./git-commit-inspector";
import { GitCommitTable } from "./git-commit-table";
import { GitLogTitleBar } from "./git-log-title-bar";
import { GitReferenceTree } from "./git-reference-tree";
import GitRemoteManager from "../git-remote-manager";

type DirectReferenceAction = Extract<
  GitReferenceAction,
  | "checkout"
  | "createBranch"
  | "checkoutAndRebase"
  | "compareWithCurrent"
  | "diffWithWorkingTree"
  | "rebaseCurrentOnto"
  | "mergeIntoCurrent"
  | "pullRebaseIntoCurrent"
  | "pullMergeIntoCurrent"
>;

export function GitLogToolWindow() {
  const { t } = useTranslation();
  const activeRepoPath = useRepositoryStore.use.activeRepoPath();
  const rootFolderPath = useProjectStore((state) => state.rootFolderPath);
  const repoPath = activeRepoPath ?? rootFolderPath ?? null;
  const setIsBottomPaneVisible = useUIState((state) => state.setIsBottomPaneVisible);
  const {
    history,
    loadState,
    error,
    selectedReference,
    isLoadingMore,
    selectReference,
    refresh,
    loadMore,
  } = useGitLogController(repoPath);
  const pullWorkflow = useGitPullWorkflow({ repoPath: repoPath ?? "", refresh });
  const [selectedCommit, setSelectedCommit] = useState<GitCommit | null>(null);
  const [selectedCommitHashes, setSelectedCommitHashes] = useState<Set<string>>(new Set());
  const [isReferenceOperating, setIsReferenceOperating] = useState(false);
  const [showRemoteManager, setShowRemoteManager] = useState(false);
  const isReferenceMutationPending = isReferenceOperating || pullWorkflow.isPulling;
  const emptyContextMenu = useDropdownMenu();
  const selectionAnchorRef = useRef<string | null>(null);
  const mainPanelLayout = useGitLogPreferencesStore.use.mainPanelLayout();
  const { setMainPanelLayout } = useGitLogPreferencesStore.use.actions();
  const currentReference = useMemo(
    () => history.references.find((reference) => reference.isCurrent) ?? null,
    [history.references],
  );
  const commitByHash = useMemo(
    () => new Map(history.commits.map((commit) => [commit.hash, commit] as const)),
    [history.commits],
  );
  const selectedCommits = useMemo(() => {
    const selected = selectedCommitsInHistoryOrder(history.commits, selectedCommitHashes);
    return selected.length > 0 ? selected : selectedCommit ? [selectedCommit] : [];
  }, [history.commits, selectedCommit, selectedCommitHashes]);
  const clearHistorySelection = useCallback(async () => {
    setSelectedCommitHashes(new Set());
    selectionAnchorRef.current = null;
    setSelectedCommit(null);
    await refresh();
  }, [refresh]);
  const {
    isMutatingHistory,
    editMessage,
    removeCommit,
    squashSelectedCommits,
    resetBranchToCommit,
    cherryPickSelectedCommit,
  } = useGitHistoryMutations({ repoPath, onCompleted: clearHistorySelection });
  const emptyWorkingTreeEntries = useMemo<Record<WorkingTreeDiffScope, WorkingTreeDiffEntry[]>>(
    () => ({
      all: [],
      staged: [],
      unstaged: [],
    }),
    [],
  );
  const emptyGitFileByPath = useMemo(() => new Map<string, GitFile>(), []);
  const {
    isLoadingCommitDiff,
    isLoadingBranchDiff,
    viewCommitDiff,
    viewCommitRangeDiff,
    viewCommitSelectionDiff,
    viewBranchDiff,
    viewReferenceWorkingTreeDiff,
  } = useGitDiffActions({
    activeRepoPath: repoPath,
    gitFileByPath: emptyGitFileByPath,
    workingTreeDiffEntriesByScope: emptyWorkingTreeEntries,
    commitByHash,
    currentBranch: currentReference?.shortName,
    currentReference: currentReference ?? undefined,
  });

  const selectCommit = (
    commit: GitCommit,
    visibleCommitHashes: string[],
    options: { additive: boolean; range: boolean },
  ) => {
    const result = updateGitHistorySelection(
      visibleCommitHashes,
      selectedCommitHashes,
      commit.hash,
      selectionAnchorRef.current,
      options,
    );
    setSelectedCommitHashes(result.selected);
    selectionAnchorRef.current = result.anchor;
    const activeHash = result.selected.has(commit.hash)
      ? commit.hash
      : visibleCommitHashes.find((hash) => result.selected.has(hash));
    setSelectedCommit(activeHash ? (commitByHash.get(activeHash) ?? null) : null);
  };

  const selectCommitForContextMenu = (commit: GitCommit) => {
    const next = resolveGitHistoryContextSelection(selectedCommitHashes, commit.hash);
    setSelectedCommitHashes(next);
    if (!selectedCommitHashes.has(commit.hash)) selectionAnchorRef.current = commit.hash;
    setSelectedCommit(commit);
  };

  const reportIntegration = (outcome: IntegrationOutcome, success: string) => {
    if (outcome.status === "clean") {
      toast.success(success);
      if (outcome.warnings?.some((warning) => warning.code === "git_stash_drop_failed")) {
        toast.warning(t("git.log.autoStashCleanupFailed"));
      }
    }
    else if (outcome.status === "conflicts") {
      if (outcome.stashRestore) {
        toast.warning(
          t("git.log.autoStashRestoreConflicts", {
            count: outcome.conflictedPaths.length,
            stash: outcome.stashRestore.stashReference,
          }),
        );
      } else if (outcome.deferredAutoStash) {
        toast.warning(
          t("git.log.autoStashDeferredByConflicts", { count: outcome.conflictedPaths.length }),
        );
      } else {
        toast.warning(t("git.log.operationConflicts", { count: outcome.conflictedPaths.length }));
      }
    } else if (outcome.status === "stopped") toast.warning(t("git.log.operationStopped"));
    else if (outcome.status === "blocked") {
      toast.error(t("git.log.operationBlocked", { paths: outcome.blockingPaths.join(", ") }));
    } else toast.error(outcome.message);
  };

  const runReferenceAction = async (reference: GitReference, action: DirectReferenceAction) => {
    if (!repoPath || isReferenceMutationPending) return;
    if (action === "compareWithCurrent") {
      await viewBranchDiff(reference);
      return;
    }
    if (action === "diffWithWorkingTree") {
      await viewReferenceWorkingTreeDiff(reference, reference.shortName);
      return;
    }
    if (action === "createBranch") {
      const name = await showPromptDialog(t("git.log.branchNamePrompt"), {
        title: t("git.log.createBranchFromTitle", { reference: reference.shortName }),
      });
      if (!name?.trim()) return;
      setIsReferenceOperating(true);
      try {
        await createAndCheckoutBranch(repoPath, name.trim(), reference);
        toast.success(t("git.log.branchCreated", { name: name.trim() }));
        await refresh();
      } catch (error) {
        toast.error(error instanceof Error ? error.message : t("git.log.branchCreateFailed"));
      } finally {
        setIsReferenceOperating(false);
      }
      return;
    }

    const confirmed = await showConfirmDialog(
      t("git.log.confirmAction", {
        action: t(`git.log.action.${action}`),
        reference: reference.shortName,
      }),
      { title: t(`git.log.action.${action}`) },
    );
    if (!confirmed) return;
    setIsReferenceOperating(true);
    try {
      if (action === "checkout") {
        const result = await checkoutGitReference(repoPath, reference);
        if (result.success) toast.success(result.message);
        else toast.error(result.message);
      } else {
        const outcome =
          action === "checkoutAndRebase"
            ? await checkoutAndRebase(repoPath, reference)
            : action === "rebaseCurrentOnto"
              ? await rebaseOntoBranch(repoPath, reference)
              : action === "mergeIntoCurrent"
                ? await mergeBranch(repoPath, reference)
                : await pullRemoteReference(
                    repoPath,
                    reference,
                    action === "pullRebaseIntoCurrent" ? "rebase" : "merge",
                  );
        if (
          outcome.status === "blocked" &&
          (action === "pullRebaseIntoCurrent" || action === "pullMergeIntoCurrent")
        ) {
          const save = await showConfirmDialog(
            t("git.log.operationBlocked", { paths: outcome.blockingPaths.join(", ") }),
            { title: t("git.stashChanges") },
          );
          if (save) {
            const retry = await pullRemoteReference(
              repoPath,
              reference,
              action === "pullRebaseIntoCurrent" ? "rebase" : "merge",
              true,
            );
            reportIntegration(
              retry,
              t("git.log.actionSucceeded", {
                action: t(`git.log.action.${action}`),
                reference: reference.shortName,
              }),
            );
          }
        } else {
          reportIntegration(
            outcome,
            t("git.log.actionSucceeded", {
              action: t(`git.log.action.${action}`),
              reference: reference.shortName,
            }),
          );
        }
      }
    } finally {
      try {
        await refresh();
      } finally {
        setIsReferenceOperating(false);
      }
    }
  };

  const referenceActionErrorMessage = (action: string, error: unknown) => {
    const reason =
      error instanceof Error
        ? error.message
        : typeof error === "object" && error && "message" in error
          ? String(error.message)
          : String(error);
    return reason || t("git.actionFailed", { action });
  };

  const runReferenceMutation = async (action: string, mutation: () => Promise<void>) => {
    if (!repoPath || isReferenceMutationPending) return;
    setIsReferenceOperating(true);
    try {
      await mutation();
      toast.success(t("git.actionCompleted", { action }));
      await refresh();
    } catch (error) {
      toast.error(referenceActionErrorMessage(action, error));
    } finally {
      setIsReferenceOperating(false);
    }
  };

  const createWorktreeFromReference = async (reference: GitReference) => {
    if (!repoPath) return;
    const branchName = await showPromptDialog(
      t("git.log.newWorktreeBranchPrompt", { branch: reference.shortName }),
      {
        title: t("git.log.newWorktreeFrom", { branch: reference.shortName }),
        confirmLabel: t("git.create"),
        defaultValue: suggestWorktreeBranchName(reference),
      },
    );
    if (!branchName?.trim()) return;
    const selectedPath = await open({
      directory: true,
      multiple: false,
      title: t("git.log.chooseWorktreeDirectory"),
    });
    if (!selectedPath || Array.isArray(selectedPath)) return;
    await runReferenceMutation(t("git.worktrees"), async () => {
      await addWorktreeFromReference(
        repoPath,
        selectedPath,
        branchName.trim(),
        reference,
      );
    });
  };

  const checkoutAndUpdateReference = async (reference: GitReference) => {
    if (!repoPath || isReferenceMutationPending || !reference.upstreamShortName) return;
    const action = t("git.log.checkoutAndUpdate");
    setIsReferenceOperating(true);
    try {
      const result = await checkoutGitReference(repoPath, reference);
      if (!result.success) throw new Error(result.message || t("git.operationFailed"));
      await pullWorkflow.pull();
    } catch (error) {
      toast.error(referenceActionErrorMessage(action, error));
    } finally {
      setIsReferenceOperating(false);
    }
  };

  const renameSelectedBranch = async (reference: GitReference) => {
    if (!repoPath) return;
    const newName = await showPromptDialog(t("git.log.renameBranchPrompt"), {
      title: t("git.log.renameBranch"),
      confirmLabel: t("git.log.renameBranch"),
      defaultValue: reference.shortName,
    });
    if (!newName?.trim() || newName.trim() === reference.shortName) return;
    await runReferenceMutation(t("git.log.renameBranch"), () =>
      renameBranch(repoPath, reference.shortName, newName.trim()),
    );
  };

  const deleteLocalReference = async (reference: GitReference) => {
    if (!repoPath) return;
    const confirmed = await showConfirmDialog(
      t("git.deleteBranchConfirm", { branch: reference.shortName }),
      { title: t("git.deleteBranch"), confirmLabel: t("git.delete") },
    );
    if (!confirmed) return;
    await runReferenceMutation(t("git.deleteBranch"), async () => {
      if (!(await deleteBranch(repoPath, reference.shortName))) {
        throw new Error(t("git.actionFailed", { action: t("git.deleteBranch") }));
      }
    });
  };

  const deleteRemoteReference = async (reference: GitReference) => {
    if (!repoPath) return;
    const confirmed = await showConfirmDialog(
      t("git.log.deleteRemoteBranchConfirm", { branch: reference.shortName }),
      { title: t("git.log.deleteRemoteBranch"), confirmLabel: t("git.delete") },
    );
    if (!confirmed) return;
    await runReferenceMutation(t("git.log.deleteRemoteBranch"), () =>
      deleteRemoteBranch(repoPath, reference),
    );
  };

  const updateCurrentBranch = async () => {
    if (!repoPath || isReferenceMutationPending) return;
    const action = t("git.log.updateBranch");
    setIsReferenceOperating(true);
    try {
      await pullWorkflow.pull();
    } catch (error) {
      toast.error(referenceActionErrorMessage(action, error));
    } finally {
      setIsReferenceOperating(false);
    }
  };

  const pushSelectedBranch = async (reference: GitReference) => {
    if (!repoPath || isReferenceMutationPending) return;
    setIsReferenceOperating(true);
    try {
      if (await showGitPushDialog(repoPath, reference)) await refresh();
    } finally {
      setIsReferenceOperating(false);
    }
  };

  const setSelectedBranchUpstream = async (branch: GitReference, upstream: GitReference | null) => {
    if (!repoPath) return;
    await runReferenceMutation(t("git.log.trackingBranch"), () =>
      upstream
        ? setBranchUpstream(repoPath, branch.shortName, upstream)
        : unsetBranchUpstream(repoPath, branch.shortName),
    );
  };

  const handleReferenceAction = (action: GitReferenceAction, reference: GitReference) => {
    switch (action) {
      case "checkout":
      case "createBranch":
      case "checkoutAndRebase":
      case "compareWithCurrent":
      case "diffWithWorkingTree":
      case "rebaseCurrentOnto":
      case "mergeIntoCurrent":
      case "pullRebaseIntoCurrent":
      case "pullMergeIntoCurrent":
        void runReferenceAction(reference, action);
        break;
      case "createWorktree":
        void createWorktreeFromReference(reference);
        break;
      case "checkoutAndUpdate":
        void checkoutAndUpdateReference(reference);
        break;
      case "update":
        void updateCurrentBranch();
        break;
      case "push":
        void pushSelectedBranch(reference);
        break;
      case "rename":
        void renameSelectedBranch(reference);
        break;
      case "deleteLocal":
        void deleteLocalReference(reference);
        break;
      case "deleteRemote":
        void deleteRemoteReference(reference);
        break;
      case "tracking":
        break;
    }
  };

  useEffect(() => {
    setSelectedCommit((current) => {
      if (current && commitByHash.has(current.hash)) return commitByHash.get(current.hash) ?? null;
      return history.commits[0] ?? null;
    });

    const availableHashes = new Set(history.commits.map((commit) => commit.hash));
    setSelectedCommitHashes((current) => {
      const next = new Set([...current].filter((hash) => availableHashes.has(hash)));
      return next.size === current.size ? current : next;
    });
    if (selectionAnchorRef.current && !availableHashes.has(selectionAnchorRef.current)) {
      selectionAnchorRef.current = null;
    }
  }, [commitByHash, history.commits]);

  const openDiff = (commit: GitCommit, filePath?: string) => {
    if (isLoadingCommitDiff) return;
    void viewCommitDiff(commit.hash, filePath);
  };

  const copyCommitText = async (text: string, label: string) => {
    if (await tryWriteClipboardText(text)) {
      toast.success(t("git.log.copied", { label }));
      return;
    }
    toast.error(t("git.log.copyFailed", { label: label.toLocaleLowerCase() }));
  };

  const comparisonBaseRef =
    selectedReference && !selectedReference.isCurrent
      ? selectedReference.fullName
      : selectedCommit?.hash;

  const handleEmptyContextMenu = (event: ReactMouseEvent) => {
    const target = event.target as HTMLElement | null;
    if (target?.closest('[data-slot="context-menu-trigger"]')) return;
    emptyContextMenu.open(event);
  };

  return (
    <div
      className="flex h-full min-h-0 flex-col overflow-hidden bg-background text-foreground"
      onContextMenu={handleEmptyContextMenu}
    >
      <GitLogTitleBar
        referenceName={selectedReference?.shortName ?? t("git.log.all")}
        isRefreshing={loadState === "loading"}
        isOpeningDiff={isLoadingCommitDiff}
        isComparing={isLoadingBranchDiff}
        hasSelectedCommit={selectedCommit !== null}
        canCompareWithHead={Boolean(comparisonBaseRef)}
        onShowAll={() => {
          setSelectedCommit(null);
          selectReference(null);
        }}
        onRefresh={() => void refresh()}
        onOpenDiff={() => {
          if (selectedCommit) openDiff(selectedCommit);
        }}
        onCompareWithHead={() => {
          if (comparisonBaseRef) void viewBranchDiff(comparisonBaseRef);
        }}
        onCopyHash={() => {
          if (selectedCommit) void copyCommitText(selectedCommit.hash, t("git.log.commitHash"));
        }}
        onClose={() => setIsBottomPaneVisible(false)}
      />

      {loadState === "failed" && history.commits.length > 0 ? (
        <div className="flex h-7 shrink-0 items-center gap-2 border-destructive/30 border-b bg-destructive/10 px-2 font-sans ui-text-sm text-destructive">
          <span className="min-w-0 flex-1 truncate">{error ?? t("git.log.unableToRefresh")}</span>
          <button
            type="button"
            className="font-medium hover:underline"
            onClick={() => void refresh()}
          >
            {t("git.log.retry")}
          </button>
        </div>
      ) : null}

      {!repoPath ? (
        <div className="flex min-h-0 flex-1 flex-col items-center justify-center gap-2 text-subtle-foreground">
          <div className="font-medium text-foreground">{t("git.log.noRepository")}</div>
          <div>{t("git.log.openWorkspace")}</div>
        </div>
      ) : loadState === "loading" && history.commits.length === 0 ? (
        <div className="flex min-h-0 flex-1 items-center justify-center text-subtle-foreground">
          {t("git.log.loading")}
        </div>
      ) : loadState === "failed" && history.commits.length === 0 ? (
        <div className="flex min-h-0 flex-1 flex-col items-center justify-center gap-3 px-6 text-center">
          <div className="text-destructive">{error ?? t("git.log.unableToLoad")}</div>
          <Button type="button" variant="ghost" size="xs" onClick={() => void refresh()}>
            {t("git.log.tryAgain")}
          </Button>
        </div>
      ) : (
        <ResizablePanelGroup
          orientation="horizontal"
          className="min-h-0 flex-1"
          defaultLayout={mainPanelLayout}
          onLayoutChanged={(layout, meta) => {
            if (meta.isUserInteraction) setMainPanelLayout(layout);
          }}
        >
          <ResizablePanel id="references" defaultSize="19" minSize={140}>
            <GitReferenceTree
              references={history.references}
              selectedReference={selectedReference}
              onSelect={(reference) => {
                setSelectedCommit(null);
                selectReference(reference);
              }}
              isMutating={isReferenceMutationPending}
              onReferenceAction={handleReferenceAction}
              onSetUpstream={(branch, upstream) => void setSelectedBranchUpstream(branch, upstream)}
              onManageRemotes={() => setShowRemoteManager(true)}
            />
          </ResizablePanel>
          <ResizableHandle />
          <ResizablePanel id="commits" defaultSize="57" minSize={320}>
            <GitCommitTable
              commits={history.commits}
              selectedCommit={selectedCommit}
              selectedCommitHashes={selectedCommitHashes}
              isMutatingHistory={isMutatingHistory}
              hasMore={history.hasMore}
              isLoadingMore={isLoadingMore}
              onSelect={selectCommit}
              onContextSelect={selectCommitForContextMenu}
              onOpenDiff={(commit) => openDiff(commit)}
              onCompareWithHead={(commit) => void viewBranchDiff(commit.hash)}
              onCopyHash={(commit) => void copyCommitText(commit.hash, t("git.log.commitHash"))}
              onCopyMessage={(commit) =>
                void copyCommitText(
                  [commit.message, commit.description].filter(Boolean).join("\n\n"),
                  t("git.log.commitMessage"),
                )
              }
              onEditMessage={(commit) => void editMessage(commit)}
              onDelete={(commit) => void removeCommit(commit)}
              onSquash={(commits) => void squashSelectedCommits(commits)}
              onReset={(commit) => void resetBranchToCommit(commit)}
              onCherryPick={(commit) => void cherryPickSelectedCommit(commit)}
              onLoadMore={() => void loadMore()}
            />
          </ResizablePanel>
          <ResizableHandle />
          <ResizablePanel id="inspector" defaultSize="24" minSize={220}>
            <GitCommitInspector
              repoPath={repoPath}
              commit={selectedCommit}
              commits={selectedCommits}
              onOpenDiff={openDiff}
              onOpenRangeDiff={(range, filePath) => {
                if (isLoadingCommitDiff) return;
                void viewCommitRangeDiff(
                  range.baseRef,
                  range.targetRef,
                  range.oldest.shortHash,
                  range.newest.shortHash,
                  filePath,
                );
              }}
              onOpenSelectionDiff={(selection, filePath) => {
                if (isLoadingCommitDiff) return;
                void viewCommitSelectionDiff(selection.commits, filePath);
              }}
            />
          </ResizablePanel>
        </ResizablePanelGroup>
      )}
      <GitRemoteManager
        isOpen={showRemoteManager}
        onClose={() => setShowRemoteManager(false)}
        repoPath={repoPath ?? undefined}
        onRefresh={() => void refresh()}
      />
      <Dropdown
        isOpen={emptyContextMenu.isOpen}
        point={emptyContextMenu.position}
        items={[
          {
            id: "no-actions-here",
            label: t("ui.noActionsHere"),
            disabled: true,
            onClick: () => {},
          },
        ]}
        onClose={emptyContextMenu.close}
      />
    </div>
  );
}
