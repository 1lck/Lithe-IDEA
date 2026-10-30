import { GitFetchDialog } from "./git-fetch-dialog";
import type { GitFetchOptions } from "../../api/git-remotes-api";
import { GitExecutionConsole } from "./git-execution-console";
import type { MouseEvent as ReactMouseEvent } from "react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { toast } from "sonner";
import { Button } from "@/ui/button";
import { showConfirmDialog, showPromptDialog } from "@/ui/dialog";
import { Dropdown, useDropdownMenu } from "@/ui/dropdown";
import { ResizableHandle, ResizablePanel, ResizablePanelGroup } from "@/ui/resizable";
import { showIdeaNotification } from "@/ui/idea-notification";
import { tryWriteClipboardText } from "@/utils/clipboard";

/** Upper bound on extra pages a reveal walks before giving up. */
const MAX_REVEAL_PAGE_ATTEMPTS = 20;
import { useTranslation } from "@/i18n/locale-provider";
import { useProjectStore } from "@/features/window/stores/project.store";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { useGitLogController } from "../../hooks/use-git-log-controller";
import { useActiveWorkspaceId } from "@/features/workspace/stores/create-workspace-scoped-store";
import { useGitWorkspaceReferences } from "../../hooks/use-git-workspace-references";
import { useGitDiffActions } from "../../hooks/use-git-diff-actions";
import {
  checkoutGitReference,
  deleteLocalBranch,
  type GitBranchDeletion,
  localBranchReference,
  renameBranch,
  restoreDeletedBranch,
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
import { withCommitDescription } from "../../api/git-commits-api";
import { deleteRemoteBranch, fetchChanges } from "../../api/git-remotes-api";
import { normalizeRepositoryPath } from "../../api/git-repo-api";
import { showGitRebaseDialog } from "../../services/git-rebase-dialog-service";
import { showGitWorktreeDialog } from "../../services/git-worktree-dialog-service";
import { useGitLogPreferencesStore } from "../../stores/git-log-preferences.store";
import { useGitLogRevealStore } from "../../stores/git-log-reveal.store";
import { useRepositoryStore } from "../../stores/git-repository.store";
import type { GitCommit, GitFile, GitReference } from "../../types/git.types";
import { useGitHistoryMutations } from "../../hooks/use-git-history-mutations";
import { useGitLogTagDeletion } from "../../hooks/use-git-log-tag-deletion";
import { useGitPullWorkflow } from "../../hooks/use-git-pull-workflow";
import {
  resolveGitHistoryContextSelection,
  selectedCommitsInHistoryOrder,
  updateGitHistorySelection,
} from "../../utils/git-history-selection";
import {
  isGitReferencePullAction,
  type GitReferenceAction,
} from "../../utils/git-reference-actions";
import { selectedReferenceAfterRename } from "../../utils/git-log-refresh";
import { showGitPushDialog } from "../../services/git-push-dialog-service";
import { updateGitLogBranch } from "../../services/git-log-branch-update";
import { getGitPullResultPresentation } from "../../utils/git-pull-result-presentation";
import { showCheckoutFailure } from "../../utils/git-checkout-failure-presentation";
import { showGitPatchDialog } from "../../services/git-patch-dialog-service";
import type {
  WorkingTreeDiffEntry,
  WorkingTreeDiffScope,
} from "../../services/working-tree-diff-loader";
import { GitCommitInspector } from "./git-commit-inspector";
import { GitCommitTable } from "./git-commit-table";
import { GitLogTitleBar } from "./git-log-title-bar";
import { GitCreateBranchDialog } from "./git-create-branch-dialog";
import { GitCreateTagDialog } from "./git-create-tag-dialog";
import { GitReferenceTree } from "./git-reference-tree";
import GitRemoteManager from "../git-remote-manager";
import { GitRepositoryEmptyState } from "../git-repository-empty-state";

// How long the "Deleted branch" notice stays up so the Restore action remains reachable.
const RESTORE_NOTICE_MS = 15_000;

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
  const workspaceId = useActiveWorkspaceId();
  const [panel, setPanel] = useState<"log" | "console">("log");
  const activeRepoPath = useRepositoryStore.use.activeRepoPath();
  const availableRepoPaths = useRepositoryStore.use.availableRepoPaths();
  const { selectRepository, syncWorkspaceRepositories } = useRepositoryStore.use.actions();
  const rootFolderPath = useProjectStore((state) => state.rootFolderPath);
  const repoPath = activeRepoPath ?? availableRepoPaths[0] ?? rootFolderPath ?? null;
  // The Log can be opened before the Source Control view has run repository
  // discovery; in that case a folder that contains repositories would show
  // "not a Git repository" until something else discovers them. Trigger it here
  // so the pane resolves to an active repository on its own.
  useEffect(() => {
    if (!rootFolderPath || availableRepoPaths.length > 0) return;
    void syncWorkspaceRepositories(rootFolderPath);
  }, [availableRepoPaths.length, rootFolderPath, syncWorkspaceRepositories]);
  const isBottomPaneVisible = useUIState((state) => state.isBottomPaneVisible);
  const setIsBottomPaneVisible = useUIState((state) => state.setIsBottomPaneVisible);
  const openSettingsDialog = useUIState((state) => state.openSettingsDialog);
  const pendingReferenceSelectionRef = useRef<GitReference | null>(null);
  // The Branch filter is restored once per repository open; later renders must not reuse it.
  const restoredRepoPathRef = useRef<string | null>(null);
  const preferredReference =
    pendingReferenceSelectionRef.current ??
    (repoPath && restoredRepoPathRef.current !== repoPath
      ? (useGitLogPreferencesStore.getState().selectedReferenceByRepository[
          normalizeRepositoryPath(repoPath)
        ] ?? null)
      : null);
  const {
    history,
    repositoryCommits,
    loadState,
    error,
    selectedReference,
    isLoadingMore,
    selectReference,
    forgetReference,
    refresh,
    loadMore,
  } = useGitLogController(repoPath, preferredReference);
  const { referencesByRepository, errorsByRepository, ensureRepository, retryRepository } =
    useGitWorkspaceReferences(availableRepoPaths, repoPath);
  const pullWorkflow = useGitPullWorkflow({ repoPath: repoPath ?? "", refresh });
  const [selectedCommit, setSelectedCommit] = useState<GitCommit | null>(null);
  const [selectedCommitHashes, setSelectedCommitHashes] = useState<Set<string>>(new Set());
  const [previewRequest, setPreviewRequest] = useState(0);
  const [graphNavigationRequest, setGraphNavigationRequest] = useState(0);
  const [isReferenceOperating, setIsReferenceOperating] = useState(false);
  const branchUpdateScope = `${workspaceId}\0${repoPath ?? ""}`;
  const latestBranchUpdateScopeRef = useRef(branchUpdateScope);
  latestBranchUpdateScopeRef.current = branchUpdateScope;
  const branchUpdateRequestRef = useRef<symbol | null>(null);
  // Notification actions outlive the render that created them, so they read the live values.
  const latestRepoPathRef = useRef(repoPath);
  latestRepoPathRef.current = repoPath;
  const latestRefreshRef = useRef(refresh);
  latestRefreshRef.current = refresh;
  const [pendingBranchUpdateScope, setPendingBranchUpdateScope] = useState<string | null>(null);
  useEffect(() => {
    setPendingBranchUpdateScope(null);
    return () => {
      branchUpdateRequestRef.current = null;
    };
  }, [branchUpdateScope]);
  const [showFetchOptions, setShowFetchOptions] = useState(false);
  const [showRemoteManager, setShowRemoteManager] = useState(false);
  const [tagRequest, setTagRequest] = useState<{
    workspaceId: string;
    repoPath: string;
    commit: GitCommit;
  } | null>(null);
  const [branchRequest, setBranchRequest] = useState<{
    workspaceId: string;
    repoPath: string;
    reference: GitReference;
  } | null>(null);
  const emptyContextMenu = useDropdownMenu();
  const selectionAnchorRef = useRef<string | null>(null);
  const mainPanelLayout = useGitLogPreferencesStore.use.mainPanelLayout();
  const { setFilterQuery, setMainPanelLayout, renameMarkedReference, setSelectedReference } =
    useGitLogPreferencesStore.use.actions();
  const currentReference = useMemo(
    () => history.references.find((reference) => reference.isCurrent) ?? null,
    [history.references],
  );
  const commitByHash = useMemo(
    () => new Map(history.commits.map((commit) => [commit.hash, commit] as const)),
    [history.commits],
  );
  const activeSelectedCommit = selectedCommit
    ? (commitByHash.get(selectedCommit.hash) ?? null)
    : null;
  const selectedCommits = useMemo(() => {
    const selected = selectedCommitsInHistoryOrder(history.commits, selectedCommitHashes);
    return selected.length > 0 ? selected : activeSelectedCommit ? [activeSelectedCommit] : [];
  }, [activeSelectedCommit, history.commits, selectedCommitHashes]);

  useEffect(() => {
    setSelectedCommit(null);
    setSelectedCommitHashes(new Set());
    selectionAnchorRef.current = null;
    setShowFetchOptions(false);
    setTagRequest(null);
    setBranchRequest(null);
  }, [repoPath]);

  useEffect(() => {
    setTagRequest(null);
    setBranchRequest(null);
  }, [workspaceId]);

  useEffect(() => {
    const pendingReference = pendingReferenceSelectionRef.current;
    if (!pendingReference) return;
    if (
      !repoPath ||
      !pendingReference.repositoryPath ||
      normalizeRepositoryPath(repoPath) !==
        normalizeRepositoryPath(pendingReference.repositoryPath)
    ) {
      return;
    }
    // The controller consumed this reference as the initial selection for the
    // repository switch; clear it so a later switch cannot reuse it.
    pendingReferenceSelectionRef.current = null;
  }, [repoPath]);

  useEffect(() => {
    restoredRepoPathRef.current = repoPath;
  }, [repoPath]);

  // Persist only once the load settled: by then a branch that no longer exists has already
  // fallen back to "All", so a stale name is never written back.
  useEffect(() => {
    if (repoPath && loadState === "ready") setSelectedReference(repoPath, selectedReference);
  }, [loadState, repoPath, selectedReference, setSelectedReference]);

  const clearHistorySelection = useCallback(async () => {
    setSelectedCommitHashes(new Set());
    selectionAnchorRef.current = null;
    setSelectedCommit(null);
    await refresh();
  }, [refresh]);
  const {
    isMutatingHistory,
    historyDialog,
    undoCommit,
    editMessage,
    removeCommit,
    squashSelectedCommits,
    resetBranchToCommit,
    cherryPickSelectedCommit,
    revertSelectedCommit,
  } = useGitHistoryMutations({ repoPath, onCompleted: clearHistorySelection });
  const isOtherGitMutationPending =
    isReferenceOperating ||
    pendingBranchUpdateScope === branchUpdateScope ||
    pullWorkflow.isPulling ||
    isMutatingHistory ||
    tagRequest !== null;
  const { deleteTagReference, isDeletingTag } = useGitLogTagDeletion({
    repoPath,
    scope: `${workspaceId}\0${repoPath ?? ""}`,
    isBlocked: isOtherGitMutationPending,
    onDeleted: async (reference) => {
      forgetReference(reference);
      await refresh();
    },
  });
  const isReferenceMutationPending = isOtherGitMutationPending || isDeletingTag;
  const navigateToSelectedBranchHead = useCallback(() => {
    if (!selectedReference || selectedReference.kind === "tag") return;
    const head = history.commits[0];
    if (!head) return;
    setFilterQuery("");
    setSelectedCommitHashes(new Set([head.hash]));
    selectionAnchorRef.current = head.hash;
    setSelectedCommit(head);
    setGraphNavigationRequest((request) => request + 1);
  }, [history.commits, selectedReference, setFilterQuery]);
  // A blame click hands over one commit hash; the log owns finding it in the
  // paginated history and selecting it. The attempt cap keeps a commit that is
  // beyond the loaded window from walking the whole history.
  const pendingReveal = useGitLogRevealStore((state) => state.pending);
  const clearReveal = useGitLogRevealStore((state) => state.clear);
  const revealAttemptsRef = useRef(0);
  useEffect(() => {
    if (!pendingReveal || !repoPath || pendingReveal.repoPath !== repoPath) return;
    if (loadState !== "ready") return;
    const commit = commitByHash.get(pendingReveal.commitHash);
    if (!commit) {
      if (
        history.hasMore &&
        !isLoadingMore &&
        revealAttemptsRef.current < MAX_REVEAL_PAGE_ATTEMPTS
      ) {
        revealAttemptsRef.current += 1;
        void loadMore();
      } else {
        revealAttemptsRef.current = 0;
        clearReveal();
      }
      return;
    }
    revealAttemptsRef.current = 0;
    setFilterQuery("");
    setSelectedCommitHashes(new Set([commit.hash]));
    selectionAnchorRef.current = commit.hash;
    setSelectedCommit(commit);
    setGraphNavigationRequest((request) => request + 1);
    clearReveal();
  }, [
    clearReveal,
    commitByHash,
    history.hasMore,
    isLoadingMore,
    loadMore,
    loadState,
    pendingReveal,
    repoPath,
    setFilterQuery,
  ]);
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
    viewCommitDiff,
    previewCommitFileDiff,
    viewCommitRangeDiff,
    viewCommitSelectionDiff,
    viewBranchDiff,
    viewReferenceWorkingTreeDiff,
  } = useGitDiffActions({
    activeRepoPath: repoPath,
    commitPreviewScope:
      isBottomPaneVisible && panel === "log" && selectedCommits.length > 0
        ? JSON.stringify(selectedCommits.map((commit) => commit.hash))
        : null,
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
    setPreviewRequest((request) => request + 1);
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
    } else if (outcome.status === "conflicts") {
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
      setBranchRequest({ workspaceId, repoPath, reference });
      return;
    }

    const confirmed =
      (action === "checkout" && reference.kind !== "tag") ||
      (await showConfirmDialog(
        t("git.log.confirmAction", {
          action: t(`git.log.action.${action}`),
          reference: reference.shortName,
        }),
        { title: t(`git.log.action.${action}`) },
      ));
    if (!confirmed) return;
    setIsReferenceOperating(true);
    try {
      if (action === "checkout") {
        // Like IDEA, a successful checkout is shown by the branch label switching, not a popup.
        const result = await checkoutGitReference(repoPath, reference);
        if (!result.success) {
          showCheckoutFailure(t, reference.shortName, result.message);
        }
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

  // A mutation may return its own success notice (for example one with a Restore action)
  // that replaces the generic "action completed" toast.
  const runReferenceMutation = async (
    action: string,
    mutation: () => Promise<void | (() => void)>,
  ) => {
    if (!repoPath || isReferenceMutationPending) return;
    setIsReferenceOperating(true);
    try {
      const notify = await mutation();
      if (notify) notify();
      else toast.success(t("git.actionCompleted", { action }));
      await refresh();
    } catch (error) {
      toast.error(referenceActionErrorMessage(action, error));
    } finally {
      setIsReferenceOperating(false);
    }
  };

  const createWorktreeFromReference = async (reference: GitReference) => {
    if (repoPath) await showGitWorktreeDialog(repoPath, { reference });
  };

  const checkoutAndUpdateReference = async (reference: GitReference) => {
    if (!repoPath || isReferenceMutationPending || !reference.upstreamShortName) return;
    const action = t("git.log.checkoutAndUpdate");
    setIsReferenceOperating(true);
    try {
      const result = await checkoutGitReference(repoPath, reference);
      if (!result.success) {
        showCheckoutFailure(t, reference.shortName, result.message);
        return;
      }
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
    const nextShortName = newName.trim();
    const renamedReference: GitReference = {
      ...reference,
      fullName: localBranchReference(nextShortName),
      shortName: nextShortName,
    };
    await runReferenceMutation(t("git.log.renameBranch"), async () => {
      await renameBranch(repoPath, reference.shortName, nextShortName);
      renameMarkedReference(repoPath, reference.fullName, renamedReference.fullName);
      const nextSelectedReference = selectedReferenceAfterRename(
        selectedReference,
        reference.fullName,
        renamedReference,
      );
      if (nextSelectedReference !== selectedReference) {
        selectReference(nextSelectedReference);
      }
    });
  };

  // Like IDEA, deleting a local branch needs no confirmation: it is undone from the
  // "Restore" action on the notification that follows.
  const restoreDeletedReference = async (
    deletedRepoPath: string,
    deletion: GitBranchDeletion,
    upstream: GitReference | undefined,
  ) => {
    try {
      await restoreDeletedBranch(deletedRepoPath, deletion);
    } catch (error) {
      toast.error(referenceActionErrorMessage(t("git.log.restoreBranch"), error));
      return;
    }
    // Deleting a branch drops its tracking configuration; bring it back when the remote
    // branch is still known. A tracking failure is only a partial success: the branch is
    // already back, so report it as a warning instead of failing the whole restore and
    // inviting the user to create a duplicate branch.
    let trackingFailure: { upstream: GitReference; error: unknown } | undefined;
    if (upstream) {
      try {
        await setBranchUpstream(deletedRepoPath, deletion.name, upstream);
      } catch (error) {
        trackingFailure = { upstream, error };
      }
    }
    if (trackingFailure) {
      toast.warning(
        t("git.log.branchRestoredUpstreamFailed", {
          name: deletion.name,
          upstream: trackingFailure.upstream.shortName,
        }),
        {
          description: referenceActionErrorMessage(
            t("git.log.restoreUpstreamTracking"),
            trackingFailure.error,
          ),
        },
      );
    } else {
      toast.success(t("git.log.branchRestored", { name: deletion.name }));
    }
    // `refresh` reports its own load failures; the branch is restored regardless.
    if (latestRepoPathRef.current === deletedRepoPath) await latestRefreshRef.current();
  };

  const deleteLocalReference = async (reference: GitReference) => {
    if (!repoPath) return;
    const deletedRepoPath = repoPath;
    const upstream = reference.upstreamShortName
      ? history.references.find(
          (candidate) =>
            candidate.kind === "remote" && candidate.shortName === reference.upstreamShortName,
        )
      : undefined;
    await runReferenceMutation(t("git.deleteBranch"), async () => {
      const deletion = await deleteLocalBranch(deletedRepoPath, reference.shortName);
      forgetReference(reference);
      // Without a recorded commit there is nothing to restore, so no action is offered.
      const actions = deletion.deletedTarget
        ? [
            {
              label: t("git.log.restoreBranch"),
              onClick: () => void restoreDeletedReference(deletedRepoPath, deletion, upstream),
            },
          ]
        : [];
      return () =>
        showIdeaNotification({
          title: t("git.log.branchDeletedTitle"),
          message: deletion.name,
          actions,
          duration: RESTORE_NOTICE_MS,
        });
    });
  };

  const deleteRemoteReference = async (reference: GitReference) => {
    if (!repoPath) return;
    const confirmed = await showConfirmDialog(
      t("git.log.deleteRemoteBranchConfirm", { branch: reference.shortName }),
      { title: t("git.log.deleteRemoteBranch"), confirmLabel: t("git.delete") },
    );
    if (!confirmed) return;
    await runReferenceMutation(t("git.log.deleteRemoteBranch"), async () => {
      await deleteRemoteBranch(repoPath, reference);
      forgetReference(reference);
    });
  };

  const updateSelectedBranch = async (reference: GitReference) => {
    if (
      !repoPath ||
      isReferenceMutationPending ||
      branchUpdateRequestRef.current ||
      latestBranchUpdateScopeRef.current !== branchUpdateScope ||
      reference.kind !== "local" ||
      !reference.upstreamShortName
    ) return;
    const action = t("git.log.updateBranch");
    const request = Symbol("update-branch");
    branchUpdateRequestRef.current = request;
    setPendingBranchUpdateScope(branchUpdateScope);
    const isCurrent = () =>
      branchUpdateRequestRef.current === request &&
      latestBranchUpdateScopeRef.current === branchUpdateScope;
    try {
      const result = await updateGitLogBranch(
        repoPath,
        reference,
        async () => {
          if (isCurrent()) await refresh();
        },
        isCurrent,
      );
      if (!isCurrent()) return;
      if (result.status === "branch-updated") {
        toast.success(t("git.actionCompleted", { action }));
      } else {
        const presentation = getGitPullResultPresentation(result, t);
        if (presentation) toast[presentation.tone](presentation.message);
      }
    } catch (error) {
      if (isCurrent()) toast.error(referenceActionErrorMessage(action, error));
    } finally {
      if (isCurrent()) {
        branchUpdateRequestRef.current = null;
        setPendingBranchUpdateScope(null);
      }
    }
  };

  const fetchReferences = async (options?: GitFetchOptions) => {
    if (!repoPath || isReferenceMutationPending) return;
    setIsReferenceOperating(true);
    try {
      const result = await fetchChanges(repoPath, options);
      if (!result.success) throw new Error(result.error || t("git.fetchFailed"));
      toast.success(t("git.changesFetched"));
    } catch (error) {
      toast.error(referenceActionErrorMessage(t("git.fetch"), error));
    } finally {
      try {
        await refresh();
      } finally {
        setIsReferenceOperating(false);
      }
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

  const handleReferenceSelect = (reference: GitReference | null) => {
    setSelectedCommit(null);
    if (
      repoPath &&
      reference?.repositoryPath &&
      normalizeRepositoryPath(reference.repositoryPath) !== normalizeRepositoryPath(repoPath)
    ) {
      pendingReferenceSelectionRef.current = reference;
      selectRepository(reference.repositoryPath);
      return;
    }
    selectReference(reference);
  };

  const handleReferenceAction =(action: GitReferenceAction, reference: GitReference) => {
    if (pullWorkflow.isPullLocked && isGitReferencePullAction(action, reference)) return;
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
        void updateSelectedBranch(reference);
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
      case "deleteTag":
        void deleteTagReference(reference);
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
      {historyDialog}
      {showFetchOptions && repoPath && <GitFetchDialog key={repoPath} root={repoPath} onClose={() => setShowFetchOptions(false)} onFetch={(options) => { setShowFetchOptions(false); void fetchReferences(options); }} />}
      <GitLogTitleBar
        referenceName={selectedReference?.shortName ?? t("git.log.all")}
        isRefreshing={loadState === "loading"}
        onShowAll={() => {
          setSelectedCommit(null);
          selectReference(null);
        }}
        onRefresh={() => void refresh()}
        onOpenSettings={() => openSettingsDialog("git")}
        onClose={() => setIsBottomPaneVisible(false)}
      />

      <div className="flex shrink-0 gap-4 border-b px-3 py-1 text-xs">
        <div className="flex gap-4" role="tablist">
          <button role="tab" aria-selected={panel === "log"} onClick={() => setPanel("log")}>{t("git.console.log")}</button>
          <button role="tab" aria-selected={panel === "console"} onClick={() => setPanel("console")}>{t("git.console.title")}</button>
        </div>
      </div>
      {panel === "console" ? <GitExecutionConsole /> : <>
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
        <GitRepositoryEmptyState root={repoPath} historyError={error} onRefresh={refresh} onShowConsole={() => setPanel("console")} />
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
              repoPath={repoPath}
              references={history.references}
              referencesByRepository={referencesByRepository}
              referenceErrorsByRepository={errorsByRepository}
              onEnsureRepository={ensureRepository}
              onRetryRepository={retryRepository}
              repositoryPaths={availableRepoPaths}
              activeRepoPath={repoPath}
              selectedReference={selectedReference}
              onSelect={handleReferenceSelect}
              isMutating={isReferenceMutationPending}
              isPullLocked={pullWorkflow.isPullLocked}
              onReferenceAction={handleReferenceAction}
              onSetUpstream={(branch, upstream) => void setSelectedBranchUpstream(branch, upstream)}
              onManageRemotes={() => setShowRemoteManager(true)}
              onFetch={() => void fetchReferences()}
              onFetchOptions={() => setShowFetchOptions(true)}
              onNavigateToHead={navigateToSelectedBranchHead}
              canNavigateToHead={
                loadState === "ready" &&
                history.commits.length > 0 &&
                selectedReference !== null &&
                selectedReference.kind !== "tag"
              }
            />
          </ResizablePanel>
          <ResizableHandle />
          <ResizablePanel id="commits" defaultSize="57" minSize={320}>
            <GitCommitTable
              emptyState={<GitRepositoryEmptyState root={repoPath} onRefresh={refresh} onShowConsole={() => setPanel("console")} />}
              commits={history.commits}
              repositoryCommits={repositoryCommits}
              references={history.references}
              selectedReference={selectedReference}
              selectedCommit={activeSelectedCommit}
              selectedCommitHashes={selectedCommitHashes}
              navigationRequest={graphNavigationRequest}
              isMutatingHistory={isReferenceMutationPending}
              hasMore={history.hasMore}
              isLoadingMore={isLoadingMore}
              onSelect={selectCommit}
              onContextSelect={selectCommitForContextMenu}
              onOpenDiff={(commit) => openDiff(commit)}
              onCompareWithHead={(commit) => void viewBranchDiff(commit.hash)}
              onCopyHash={(commit) => void copyCommitText(commit.hash, t("git.log.commitHash"))}
              onCopyShortHash={(commit) => void copyCommitText(commit.shortHash, commit.shortHash)}
              onCopyMessage={(commit) =>
                void (async () => {
                  const detailed = repoPath
                    ? await withCommitDescription(repoPath, commit)
                    : commit;
                  await copyCommitText(
                    [detailed.message, detailed.description].filter(Boolean).join("\n\n"),
                    t("git.log.commitMessage"),
                  );
                })()
              }
              onEditMessage={(commit) => void editMessage(commit)}
              onUndo={(commit) => void undoCommit(commit)}
              onInteractiveRebase={(commit) => {
                if (repoPath) showGitRebaseDialog(repoPath, commit.hash);
              }}
              onExportPatch={(commits) => {
                if (repoPath) void showGitPatchDialog(repoPath, { mode: "export", commits });
              }}
              onDelete={(commit) => void removeCommit(commit)}
              onSquash={(commits) => void squashSelectedCommits(commits)}
              onReset={(commit) => void resetBranchToCommit(commit)}
              onCherryPick={(commit) => void cherryPickSelectedCommit(commit)}
              onRevert={(commit) => void revertSelectedCommit(commit)}
              onCreateTag={(commit) => {
                if (repoPath && !isReferenceMutationPending) {
                  setTagRequest({ workspaceId, repoPath, commit });
                }
              }}
              onLoadMore={() => void loadMore()}
              onSelectReference={handleReferenceSelect}
            />
          </ResizablePanel>
          <ResizableHandle />
          <ResizablePanel id="inspector" defaultSize="24" minSize={220}>
            <GitCommitInspector
              repoPath={repoPath}
              commit={activeSelectedCommit}
              commits={selectedCommits}
              previewRequest={previewRequest}
              onPreviewFile={previewCommitFileDiff}
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
      </>}
      {branchRequest?.repoPath === repoPath && branchRequest.workspaceId === workspaceId ? (
        <GitCreateBranchDialog
          key={`${branchRequest.repoPath}\0${branchRequest.reference.fullName}`}
          repoPath={branchRequest.repoPath}
          reference={branchRequest.reference}
          references={history.references}
          // Creating (and checking out) a branch needs no popup; only a failure is reported.
          onCreated={async () => {
            await refresh();
          }}
          onClose={() => setBranchRequest(null)}
        />
      ) : null}
      {tagRequest?.repoPath === repoPath && tagRequest.workspaceId === workspaceId ? (
        <GitCreateTagDialog
          key={`${tagRequest.repoPath}\0${tagRequest.commit.hash}`}
          repoPath={tagRequest.repoPath}
          commit={tagRequest.commit}
          onCreated={refresh}
          onClose={() => setTagRequest(null)}
        />
      ) : null}
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
