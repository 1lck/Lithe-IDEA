import { GitChangelistBar } from "./git-changelist-bar";
import { useGitChangelistsStore, workspaceChangelists } from "../stores/git-changelists.store";
import { useWorkspaceCommitStore } from "../stores/git-workspace-commit.store";
import { changelistCommitScope, fileChangelist } from "../utils/git-changelists";
import { workspaceCommitBindings } from "../utils/git-workspace-commit-bindings";
import { open } from "@tauri-apps/plugin-dialog";
import {
  ArchiveIcon as Archive,
  ClockCounterClockwiseIcon as ClockCounterClockwise,
  DownloadIcon as Download,
  DotsThreeIcon as MoreHorizontal,
  FolderSimpleStarIcon as FolderSimpleStar,
  GitBranchIcon as GitBranch,
  RefreshIcon as RefreshCw,
  TrashIcon as Trash2,
  UploadIcon as Upload,
} from "@/ui/icons";
import {
  memo,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
} from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { Button } from "@/ui/button";
import { CommandEmpty, CommandItemBadge, CommandItemRow, CommandList } from "@/ui/command";
import { Empty, EmptyContent, EmptyDescription, EmptyHeader, EmptyTitle } from "@/ui/empty";
import { Spinner } from "@/ui/spinner";
import { showAlertDialog } from "@/ui/dialog";
import {
  SidebarFooter,
  SidebarHeaderIconButton,
  SidebarPanel,
  SidebarTitleBar,
} from "@/ui/sidebar";
import { toast } from "sonner";
import { formatRelativeDate } from "@/utils/date";
import { joinPath } from "@/utils/path-helpers";
import { matchesSearchQuery } from "@/utils/search-match";
import { getBranches } from "../api/git-branches-api";
import { useGitCommitPicker } from "../hooks/use-git-commit-picker";
import {
  useActiveWorkspaceId,
  useWorkspaceStoreScopeId,
} from "@/features/workspace/stores/create-workspace-scoped-store";
import { clearRepositoryDiscoveryCache, resolveRepositoryPath } from "../api/git-repo-api";
import { getRemotes } from "../api/git-remotes-api";
import { applyStash, dropStash, popStash } from "../api/git-stash-api";
import { getGitStatus, initRepository } from "../api/git-status-api";
import { useGitCommitAreaResize } from "../hooks/use-git-commit-area-resize";
import { useGitDataController } from "../hooks/use-git-data-controller";
import { useGitDiffActions } from "../hooks/use-git-diff-actions";
import { useGitPullWorkflow } from "../hooks/use-git-pull-workflow";
import { useGitBlameStore } from "../stores/git-blame.store";
import { useRepositoryStore } from "../stores/git-repository.store";
import { useGitStore } from "../stores/git.store";
import type { GitFile } from "../types/git.types";
import { buildVisibleGitFiles } from "../utils/git-status-model";
import {
  type WorkingTreeDiffEntry,
  type WorkingTreeDiffScope,
} from "../services/working-tree-diff-loader";
import type { GitActionsMenuAnchorRect } from "../utils/git-actions-menu-position";
import { getStashDisplayTitle, getStashPositionLabel } from "../utils/git-stash-format";
import GitActionsMenu from "./git-actions-menu";
import GitCommitPanel from "./git-commit-panel";
import GitCommandSurface from "./git-command-surface";
import GitRemoteManager from "./git-remote-manager";
import GitTagManager from "./git-tag-manager";
import GitOperationBanner from "./git-operation-banner";
import GitStatusPanel from "./status/git-status-panel";
import { GitRepositoryEmptyState } from "./git-repository-empty-state";

interface GitViewProps {
  repoPath?: string;
  onFileSelect?: (path: string, isDir: boolean) => void;
  isActive?: boolean;
}

const GIT_VIEW_BRANCH_MANAGER_EVENT = "lithe:open-branch-manager";

type GitPaletteAction =
  | { type: "select-repository" }
  | { type: "manage-branches"; tab?: "branches" | "worktrees" | "repositories" }
  | { type: "show-branch-diff" }
  | { type: "manage-remotes" }
  | { type: "manage-tags" }
  | { type: "view-stashes" }
  | { type: "initialize-repository" }
  | { type: "refresh" };

const GitView = ({ repoPath, onFileSelect, isActive }: GitViewProps) => {
  const { t } = useTranslation();
  const gitStatus = useGitStore((state) => state.gitStatus);
  const isLoadingGitData = useGitStore((state) => state.isLoadingGitData);
  const isRefreshing = useGitStore((state) => state.isRefreshing);
  const actions = useGitStore((state) => state.actions);
  const activeWorkspaceId = useActiveWorkspaceId();
  const scopedWorkspaceId = useWorkspaceStoreScopeId();
  const branches = useGitStore((state) => state.branches);
  const stashes = useGitStore((state) => state.stashes);
  const { syncWorkspaceRepositories, setManualRepository } = useRepositoryStore.use.actions();
  const {
    activeRepoPath,
    hasLoadError,
    refresh: handleManualRefresh,
    refreshWorkingTree,
  } = useGitDataController({
    workspacePath: repoPath,
    isActive,
  });
  const sourceControlSession = useGitStore((state) =>
    activeRepoPath ? state.sourceControlSessions[activeRepoPath] : undefined,
  );
  const refreshPullState = useCallback(async () => {
    if (!activeRepoPath) return;
    await Promise.all([handleManualRefresh(), getRemotes(activeRepoPath)]);
  }, [activeRepoPath, handleManualRefresh]);
  const pullWorkflow = useGitPullWorkflow({
    repoPath: activeRepoPath ?? "",
    refresh: refreshPullState,
  });
  const handlePull = useCallback(async () => {
    if (!activeRepoPath) {
      toast.error(t("git.noRepositoryOpen"));
      return;
    }
    const result = await pullWorkflow.pull();
    if (result.status === "pulled") {
      useGitBlameStore.getState().actions.clearAllBlame();
    }
  }, [activeRepoPath, pullWorkflow.pull]);
  const [showGitActionsMenu, setShowGitActionsMenu] = useState(false);
  const [showStashList, setShowStashList] = useState(false);
  const [isSelectingRepo, setIsSelectingRepo] = useState(false);
  const [isInitializingRepo, setIsInitializingRepo] = useState(false);
  const [repoSelectionError, setRepoSelectionError] = useState<string | null>(null);
  const [gitActionsMenuAnchor, setGitActionsMenuAnchor] = useState<GitActionsMenuAnchorRect | null>(
    null,
  );
  const [showRemoteManager, setShowRemoteManager] = useState(false);
  const [showTagManager, setShowTagManager] = useState(false);
  const showUntrackedFiles = useSettingsStore((state) => state.settings.showUntrackedFiles);
  const openDiffOnClick = useSettingsStore((state) => state.settings.openDiffOnClick);
  const [isStaging, setIsStaging] = useState(false);
  const [commitFocusRequest, setCommitFocusRequest] = useState(0);
  const repositoryPaths = useRepositoryStore((state) => state.availableRepoPaths);
  const collapsedStatusFolders = useMemo(
    () => new Set(sourceControlSession?.collapsedFolders ?? []),
    [sourceControlSession],
  );
  const collapsedStatusSections = useMemo(
    () => new Set(sourceControlSession?.collapsedSections ?? []),
    [sourceControlSession],
  );
  const updateSourceControlSession = useCallback(
    (update: Parameters<typeof actions.updateSourceControlSession>[1]) => {
      if (!activeRepoPath) return;
      actions.updateSourceControlSession(activeRepoPath, update);
    },
    [actions, activeRepoPath],
  );
  const [showCommitDiffList, setShowCommitDiffList] = useState(false);
  const commitPicker = useGitCommitPicker(
    activeRepoPath,
    scopedWorkspaceId ?? activeWorkspaceId,
    showCommitDiffList,
  );
  const commits = commitPicker.commits;
  const [commitDiffSearchQuery, setCommitDiffSearchQuery] = useState("");
  const [showBranchDiffList, setShowBranchDiffList] = useState(false);
  const [branchDiffSearchQuery, setBranchDiffSearchQuery] = useState("");
  const [stashSearchQuery, setStashSearchQuery] = useState("");
  const [stashActionLoading, setStashActionLoading] = useState<Set<number>>(new Set());

  const { gitFileByPath, visibleGitFiles, workingTreeDiffEntriesByScope } = useMemo(() => {
    const visible = buildVisibleGitFiles(gitStatus?.files ?? [], showUntrackedFiles);
    const nextWorkingTreeDiffEntriesByScope: Record<WorkingTreeDiffScope, WorkingTreeDiffEntry[]> =
      {
        all: [],
        unstaged: [],
        staged: [],
      };
    const seenDiffableFileKeys = new Set<string>();

    for (const file of visible.files) {
      const fileKey = `${file.staged ? "staged" : "unstaged"}:${file.path}`;

      if (seenDiffableFileKeys.has(fileKey)) {
        continue;
      }

      seenDiffableFileKeys.add(fileKey);
      const entry: WorkingTreeDiffEntry = [fileKey, file];
      nextWorkingTreeDiffEntriesByScope.all.push(entry);
      nextWorkingTreeDiffEntriesByScope[file.staged ? "staged" : "unstaged"].push(entry);
    }

    return {
      gitFileByPath: visible.fileByPath,
      visibleGitFiles: visible.files,
      workingTreeDiffEntriesByScope: nextWorkingTreeDiffEntriesByScope,
    };
  }, [gitStatus?.files, showUntrackedFiles]);
  const changesAreaRef = useRef<HTMLDivElement>(null);
  const commitAreaRef = useRef<HTMLDivElement>(null);
  const commitAreaResize = useGitCommitAreaResize(commitAreaRef, changesAreaRef);
  const commitByHash = useMemo(() => {
    return new Map(commits.map((commit) => [commit.hash, commit] as const));
  }, [commits]);
  const changelistWorkspace = repoPath ?? activeRepoPath ?? "";
  const changelists = useGitChangelistsStore((state) =>
    workspaceChangelists(state, changelistWorkspace),
  );
  useEffect(() => {
    useGitChangelistsStore
      .getState()
      .rememberRenames(changelistWorkspace, gitStatus?.files ?? [], activeRepoPath ?? undefined);
  }, [changelistWorkspace, gitStatus?.files, activeRepoPath]);
  const changelistsUnavailable = useGitChangelistsStore((state) => state.unavailable);
  const workflow = useWorkspaceCommitStore((state) => state.workflow);
  const batch = useSyncExternalStore(workflow.subscribe, workflow.getState, workflow.getState);
  const changelistsBusy =
    isStaging ||
    batch.busy ||
    Boolean(batch.review) ||
    Boolean(batch.session && !batch.session.succeeded);
  const commitSelectedFiles = useMemo(
    () =>
      (gitStatus?.files ?? []).filter(
        (file) =>
          file.staged &&
          fileChangelist(changelists, file, activeRepoPath ?? undefined) === changelists.activeId,
      ),
    [gitStatus?.files, changelists, activeRepoPath],
  );
  const otherListsStaged = (gitStatus?.files ?? []).some(
    (file) =>
      file.staged &&
      fileChangelist(changelists, file, activeRepoPath ?? undefined) !== changelists.activeId,
  );
  const pathScope = useMemo(
    () =>
      changelistCommitScope(
        changelists,
        workspaceCommitBindings(
          changelistWorkspace,
          repositoryPaths.length ? repositoryPaths : activeRepoPath ? [activeRepoPath] : [],
        ),
        gitStatus?.files ?? [],
        activeRepoPath ?? undefined,
      ),
    [changelists, changelistWorkspace, repositoryPaths, activeRepoPath, gitStatus?.files],
  );
  const handleBranchDiffOpened = useCallback(() => {
    setShowBranchDiffList(false);
    setBranchDiffSearchQuery("");
  }, []);
  const {
    isLoadingCommitDiff,
    isLoadingBranchDiff,
    openOriginalFile: handleOpenOriginalFile,
    viewFileDiff: handleViewFileDiff,
    viewWorkingTreeDiff: handleViewWorkingTreeDiff,
    viewCommitDiff: handleViewCommitDiff,
    viewStashDiff: handleViewStashDiff,
    viewTagComparison: handleViewTagComparison,
    viewBranchDiff: handleViewBranchDiff,
  } = useGitDiffActions({
    activeRepoPath,
    onFileSelect,
    gitFileByPath,
    workingTreeDiffEntriesByScope,
    commitByHash,
    currentBranch: gitStatus?.branch,
    onBranchDiffOpened: handleBranchDiffOpened,
  });
  const handleOpenGitPath = useCallback(
    (path: string, isDirectory: boolean, repositoryPath?: string) => {
      if (isDirectory) {
        const root = repositoryPath ?? activeRepoPath;
        if (!root || !onFileSelect) return;
        onFileSelect(joinPath(root, path), true);
        return;
      }
      void handleOpenOriginalFile(path);
    },
    [activeRepoPath, handleOpenOriginalFile, onFileSelect],
  );

  const handleSelectRepository = useCallback(async () => {
    setIsSelectingRepo(true);
    setRepoSelectionError(null);
    try {
      const selected = await open({
        directory: true,
        multiple: false,
      });

      if (!selected || Array.isArray(selected)) {
        return;
      }

      const resolvedRepoPath = await resolveRepositoryPath(selected);
      if (!resolvedRepoPath) {
        const message = t("git.selectedFolderNotRepo");
        setRepoSelectionError(message);
        await showAlertDialog(message, t("git.selectRepository"));
        return;
      }

      setManualRepository(resolvedRepoPath);
    } catch (error) {
      console.error("Failed to select repository:", error);
      const message = t("git.failedToSelectRepository");
      setRepoSelectionError(message);
      await showAlertDialog(`${message}:\n${error}`, t("git.selectRepository"));
    } finally {
      setIsSelectingRepo(false);
    }
  }, [setManualRepository]);

  const handleInitializeRepository = useCallback(async () => {
    const targetPath = repoPath;

    if (!targetPath) {
      toast.error(t("git.openFolderBeforeInit"));
      return;
    }

    setIsInitializingRepo(true);
    setRepoSelectionError(null);
    try {
      const success = await initRepository(targetPath);
      if (!success) {
        const message = t("git.failedToInitializeRepository");
        setRepoSelectionError(message);
        toast.error(message);
        return;
      }

      clearRepositoryDiscoveryCache();
      setManualRepository(targetPath);
      await syncWorkspaceRepositories(targetPath, { force: true });
      toast.success(t("git.repositoryInitialized"));
    } catch (error) {
      console.error("Failed to initialize repository:", error);
      const message =
        error instanceof Error ? error.message : t("git.failedToInitializeRepository");
      setRepoSelectionError(message);
      toast.error(message);
    } finally {
      setIsInitializingRepo(false);
    }
  }, [repoPath, setManualRepository, syncWorkspaceRepositories]);

  useEffect(() => {
    setRepoSelectionError(null);
  }, [repoPath]);

  const handleOpenBranchManager = useCallback(
    (tab: "branches" | "worktrees" | "repositories" = "branches") => {
      window.dispatchEvent(new CustomEvent(GIT_VIEW_BRANCH_MANAGER_EVENT, { detail: { tab } }));
    },
    [],
  );

  const handleShowBranchDiffList = useCallback(async () => {
    setShowBranchDiffList(true);
    setBranchDiffSearchQuery("");

    if (!activeRepoPath) return;

    try {
      actions.setBranches(await getBranches(activeRepoPath));
    } catch (error) {
      console.error("Failed to load branches for diff:", error);
    }
  }, [activeRepoPath, actions]);

  const handleShowCommitDiffList = useCallback(() => {
    setShowCommitDiffList(true);
    setCommitDiffSearchQuery("");
  }, []);

  useEffect(() => {
    const handlePaletteAction = (event: Event) => {
      if (!(event instanceof CustomEvent)) return;

      const detail = event.detail as GitPaletteAction;
      if (!detail) return;

      if (detail.type === "select-repository") {
        void handleSelectRepository();
        return;
      }

      if (detail.type === "manage-branches") {
        handleOpenBranchManager(detail.tab);
        return;
      }

      if (detail.type === "show-branch-diff") {
        void handleShowBranchDiffList();
        return;
      }

      if (detail.type === "manage-remotes") {
        setShowRemoteManager(true);
        return;
      }

      if (detail.type === "manage-tags") {
        setShowTagManager(true);
        return;
      }

      if (detail.type === "view-stashes") {
        setShowStashList(true);
        setStashSearchQuery("");
        return;
      }

      if (detail.type === "initialize-repository") {
        void handleInitializeRepository();
        return;
      }

      if (detail.type === "refresh") {
        void handleManualRefresh();
      }
    };

    window.addEventListener("lithe:git-palette-action", handlePaletteAction);
    return () => window.removeEventListener("lithe:git-palette-action", handlePaletteAction);
  }, [
    handleInitializeRepository,
    handleManualRefresh,
    handleOpenBranchManager,
    handleSelectRepository,
    handleShowBranchDiffList,
  ]);

  const handleStashListAction = async (
    action: () => Promise<boolean>,
    stashIndex: number,
    actionName: string,
  ) => {
    if (!activeRepoPath) return;

    setStashActionLoading((prev) => new Set(prev).add(stashIndex));
    try {
      const success = await action();
      if (success) {
        await handleManualRefresh();
      } else {
        console.error(`${actionName} failed`);
      }
    } catch (error) {
      console.error(`${actionName} error:`, error);
    } finally {
      setStashActionLoading((prev) => {
        const next = new Set(prev);
        next.delete(stashIndex);
        return next;
      });
    }
  };

  const renderActionsButton = () => (
    <SidebarHeaderIconButton
      onClick={(e) => {
        const rect = e.currentTarget.getBoundingClientRect();
        setGitActionsMenuAnchor({
          left: rect.left,
          right: rect.right,
          top: rect.top,
          bottom: rect.bottom,
          width: rect.width,
          height: rect.height,
        });
        setShowGitActionsMenu(!showGitActionsMenu);
        setShowStashList(false);
      }}
      tooltip={t("git.actions")}
    >
      <MoreHorizontal />
    </SidebarHeaderIconButton>
  );

  const renderRefreshButton = () => (
    <SidebarHeaderIconButton
      onClick={handleManualRefresh}
      disabled={isLoadingGitData || isRefreshing}
      tooltip={t("git.refresh")}
      aria-label={t("git.refreshAria")}
    >
      {isLoadingGitData || isRefreshing ? (
        <Spinner label={t("git.refreshAria")} compact />
      ) : (
        <RefreshCw />
      )}
    </SidebarHeaderIconButton>
  );

  const renderInitializeRepositoryButton = () => {
    const canInitializeRepository = Boolean(repoPath);

    return (
      <Button
        onClick={() => void handleInitializeRepository()}
        disabled={!canInitializeRepository || isInitializingRepo}
        variant="ghost"
        size="xs"
        tooltip={
          canInitializeRepository
            ? t("git.initializeGitRepository")
            : t("git.openFolderBeforeInitializing")
        }
      >
        <GitBranch weight="duotone" />
        {isInitializingRepo ? t("git.initializing") : t("git.initialize")}
      </Button>
    );
  };

  const renderRepositoryEmptyActions = () => (
    <>
      <Button
        type="button"
        variant="default"
        size="xs"
        disabled={isSelectingRepo}
        onClick={() => void handleSelectRepository()}
      >
        <FolderSimpleStar weight="duotone" />
        {isSelectingRepo ? t("git.selecting") : t("git.browse")}
      </Button>
      {renderInitializeRepositoryButton()}
    </>
  );

  const renderGitActionsMenu = ({
    hasGitRepo,
    onRefresh,
  }: {
    hasGitRepo: boolean;
    onRefresh?: () => void;
  }) => (
    <GitActionsMenu
      isOpen={showGitActionsMenu}
      anchorRect={gitActionsMenuAnchor}
      onClose={() => {
        setShowGitActionsMenu(false);
        setGitActionsMenuAnchor(null);
      }}
      hasGitRepo={hasGitRepo}
      repoPath={activeRepoPath ?? repoPath}
      onRefresh={onRefresh}
      onPull={handlePull}
      isPulling={pullWorkflow.isPulling}
      isPullLocked={pullWorkflow.isPullLocked}
      onOpenBranchManager={handleOpenBranchManager}
      onShowBranchDiff={() => void handleShowBranchDiffList()}
      onOpenRemoteManager={() => setShowRemoteManager(true)}
      onOpenTagManager={() => setShowTagManager(true)}
      onViewStashes={() => {
        setShowStashList(true);
        setStashSearchQuery("");
      }}
      onSelectRepository={handleSelectRepository}
      isSelectingRepository={isSelectingRepo}
      onInitializeRepository={handleInitializeRepository}
      isInitializingRepository={isInitializingRepo}
    />
  );

  const filteredStashes = useMemo(() => {
    const query = stashSearchQuery.trim().toLowerCase();
    if (!query) {
      return stashes;
    }

    return stashes.filter((stash) =>
      matchesSearchQuery(query, [
        getStashDisplayTitle(stash.message),
        getStashPositionLabel(stash.index),
        `stash ${stash.index + 1}`,
        `stash@{${stash.index}}`,
      ]),
    );
  }, [stashSearchQuery, stashes]);
  const filteredDiffCommits = useMemo(() => {
    const query = commitDiffSearchQuery.trim().toLowerCase();
    if (!query) {
      return commits;
    }

    return commits.filter((commit) =>
      matchesSearchQuery(query, [
        commit.message,
        commit.description ?? "",
        commit.author,
        commit.email ?? "",
        commit.hash,
        commit.hash.substring(0, 7),
      ]),
    );
  }, [commitDiffSearchQuery, commits]);
  const branchDiffBranches = useMemo(
    () => branches.filter((branch) => branch !== gitStatus?.branch),
    [branches, gitStatus?.branch],
  );

  const filteredBranchDiffBranches = useMemo(() => {
    const query = branchDiffSearchQuery.trim().toLowerCase();
    if (!query) {
      return branchDiffBranches;
    }

    return branchDiffBranches.filter((branch) => matchesSearchQuery(query, [branch]));
  }, [branchDiffBranches, branchDiffSearchQuery]);

  if (!activeRepoPath) {
    return (
      <>
        <SidebarPanel>
          <SidebarTitleBar title={t("workbench.commit")}>
            {renderActionsButton()}
          </SidebarTitleBar>
          {repoPath ? (
            <GitRepositoryEmptyState
              root={repoPath}
              context="changes"
              onRefresh={handleManualRefresh}
            />
          ) : (
            <Empty className="h-full">
              <EmptyHeader>
                <EmptyTitle>{t("git.noRepositorySelected")}</EmptyTitle>
                {repoSelectionError ? (
                  <EmptyDescription className="text-destructive">
                    {repoSelectionError}
                  </EmptyDescription>
                ) : null}
              </EmptyHeader>
              <EmptyContent className="flex-row">{renderRepositoryEmptyActions()}</EmptyContent>
            </Empty>
          )}
        </SidebarPanel>
        {renderGitActionsMenu({ hasGitRepo: false, onRefresh: handleManualRefresh })}
      </>
    );
  }

  if (isLoadingGitData && !gitStatus) {
    return (
      <>
        <SidebarPanel>
          <SidebarTitleBar title={t("workbench.commit")}>
            {renderActionsButton()}
          </SidebarTitleBar>
          <Spinner label={t("git.loadingGitStatus")} showLabel compact className="m-auto" />
        </SidebarPanel>
        {renderGitActionsMenu({ hasGitRepo: false, onRefresh: handleManualRefresh })}
      </>
    );
  }

  const showLoadError = hasLoadError;
  const loadError = (
    <div
      role="alert"
      className="flex items-center justify-between gap-2 p-3 ui-text-sm text-destructive"
    >
      <span>{t("git.statusLoadFailed")}</span>
      <Button
        size="xs"
        variant="ghost"
        disabled={isRefreshing}
        onClick={() => void handleManualRefresh()}
      >
        {t("git.log.retry")}
      </Button>
    </div>
  );

  if (!gitStatus) {
    return (
      <>
        <SidebarPanel>
          <SidebarTitleBar title={t("workbench.commit")}>
            {renderActionsButton()}
          </SidebarTitleBar>
          <GitRepositoryEmptyState
            root={activeRepoPath}
            context="changes"
            onRefresh={handleManualRefresh}
          />
        </SidebarPanel>
        {renderGitActionsMenu({ hasGitRepo: false, onRefresh: handleManualRefresh })}
      </>
    );
  }

  const refreshAfterAction = handleManualRefresh;
  const handleGitFileClick = openDiffOnClick ? handleViewFileDiff : handleOpenOriginalFile;

  return (
    <>
      <SidebarPanel className="font-sans ui-text-sm select-none">
        <SidebarTitleBar title={t("workbench.commit")}>
          {renderRefreshButton()}
          {renderActionsButton()}
        </SidebarTitleBar>
        {showLoadError && loadError}
        <div className="flex min-h-0 flex-1 flex-col overflow-hidden isolate">
          <div ref={changesAreaRef} className="flex h-full min-h-0 flex-1 flex-col overflow-hidden">
            <GitOperationBanner repoPath={activeRepoPath} />
            <GitChangelistBar workspace={changelistWorkspace} disabled={changelistsBusy} />
            <GitStatusPanel
              changelists={changelists}
              changelistsDisabled={changelistsBusy}
              stagingDisabled={changelistsUnavailable}
              onMoveToChangelist={(files, id) => {
                if (!changelistsBusy)
                  useGitChangelistsStore
                    .getState()
                    .moveFiles(changelistWorkspace, files, id, activeRepoPath ?? undefined);
              }}
              files={visibleGitFiles}
              repositoryCount={repositoryPaths.length}
              collapsedFolders={collapsedStatusFolders}
              onCollapsedFoldersChange={(folders) =>
                updateSourceControlSession({ collapsedFolders: [...folders].sort() })
              }
              collapsedSections={collapsedStatusSections}
              onCollapsedSectionsChange={(sections) =>
                updateSourceControlSession({ collapsedSections: [...sections].sort() })
              }
              onFileSelect={handleGitFileClick}
              onOpenPath={handleOpenGitPath}
              onViewDiff={(scope) => void handleViewWorkingTreeDiff(scope)}
              onViewFilesDiff={(filePaths) => void handleViewWorkingTreeDiff("all", filePaths)}
              onCommitSelection={() => setCommitFocusRequest((request) => request + 1)}
              onShowCommitDiffPicker={handleShowCommitDiffList}
              onShowBranchDiffPicker={() => void handleShowBranchDiffList()}
              onShowStashDiffPicker={() => {
                setShowStashList(true);
                setStashSearchQuery("");
              }}
              onStagingRefresh={refreshWorkingTree}
              onStagingPendingChange={setIsStaging}
              onRefresh={refreshAfterAction}
              repoPath={activeRepoPath}
            />
          </div>

          {/* IntelliJ commit area: no card frame, one draggable divider separating it from
              the changes list. */}
          <SidebarFooter
            ref={commitAreaRef}
            style={commitAreaResize.commitAreaStyle}
            className="mx-0 mb-0 rounded-none border-0 border-t border-border"
          >
            <div
              role="separator"
              aria-orientation="horizontal"
              aria-label={t("git.resizeCommitArea")}
              aria-valuenow={commitAreaResize.commitMessageHeight}
              tabIndex={0}
              onPointerDown={commitAreaResize.startResize}
              onKeyDown={commitAreaResize.handleKeyDown}
              className="absolute inset-x-0 -top-1 z-30 h-2 cursor-ns-resize outline-none focus-visible:bg-primary/20"
              data-testid="git-commit-area-resize-handle"
            />

            <GitCommitPanel
              pathScope={pathScope}
              commitScopeError={
                changelistsUnavailable
                  ? t("git.changelists.unavailable")
                  : otherListsStaged
                    ? t("git.changelists.otherStaged")
                    : undefined
              }
              selectedFiles={commitSelectedFiles}
              isStaging={isStaging}
              workspacePath={repoPath ?? activeRepoPath ?? ""}
              repositoryPaths={
                repositoryPaths.length ? repositoryPaths : activeRepoPath ? [activeRepoPath] : []
              }
              commitMessage={sourceControlSession?.commitMessage ?? ""}
              onCommitMessageChange={(commitMessage) =>
                updateSourceControlSession({ commitMessage })
              }
              currentBranch={gitStatus.branch}
              repoPath={activeRepoPath}
              ahead={gitStatus.ahead}
              behind={gitStatus.behind}
              onPull={handlePull}
              isPulling={pullWorkflow.isPulling}
              isPullLocked={pullWorkflow.isPullLocked}
              focusRequest={commitFocusRequest}
            />
          </SidebarFooter>
        </div>
      </SidebarPanel>

      {renderGitActionsMenu({ hasGitRepo: !!gitStatus, onRefresh: refreshAfterAction })}
      <GitCommandSurface
        isOpen={showCommitDiffList}
        onClose={() => {
          setShowCommitDiffList(false);
          setCommitDiffSearchQuery("");
        }}
        query={commitDiffSearchQuery}
        onQueryChange={setCommitDiffSearchQuery}
        placeholder={t("git.searchCommits")}
        meta={t(commits.length === 1 ? "git.commitCount" : "git.commitsCount", {
          count: commits.length,
        })}
      >
        <CommandList>
          {commitPicker.status === "failed" ? (
            <div
              role="alert"
              className="flex items-center justify-between gap-2 p-3 ui-text-sm text-destructive"
            >
              <span>{t("git.historyLoadFailed")}</span>
              <Button size="xs" variant="ghost" onClick={commitPicker.retry}>
                {t("ui.retry")}
              </Button>
            </div>
          ) : commitPicker.status === "loading" ? (
            <Spinner label={t("git.loadingCommits")} showLabel compact className="m-auto py-4" />
          ) : filteredDiffCommits.length === 0 ? (
            <CommandEmpty>
              {commitDiffSearchQuery.trim() ? t("git.noMatchingCommits") : t("git.noCommits")}
            </CommandEmpty>
          ) : (
            <div className="space-y-1">
              {filteredDiffCommits.map((commit) => {
                const shortHash = commit.hash.substring(0, 7);

                return (
                  <CommandItemRow
                    key={commit.hash}
                    type="button"
                    icon={<ClockCounterClockwise size={14} className="text-subtle-foreground" />}
                    title={commit.message}
                    accessory={<CommandItemBadge>{shortHash}</CommandItemBadge>}
                    onClick={() => {
                      void handleViewCommitDiff(commit.hash);
                      setShowCommitDiffList(false);
                      setCommitDiffSearchQuery("");
                    }}
                    disabled={isLoadingCommitDiff}
                    className="min-h-9"
                  />
                );
              })}
            </div>
          )}
        </CommandList>
      </GitCommandSurface>
      <GitCommandSurface
        isOpen={showBranchDiffList}
        onClose={() => {
          setShowBranchDiffList(false);
          setBranchDiffSearchQuery("");
        }}
        query={branchDiffSearchQuery}
        onQueryChange={setBranchDiffSearchQuery}
        placeholder={t("git.compareBranchPlaceholder")}
        meta={t(branchDiffBranches.length === 1 ? "git.branchCount" : "git.branchesCount", {
          count: branchDiffBranches.length,
        })}
      >
        <CommandList>
          {filteredBranchDiffBranches.length === 0 ? (
            <CommandEmpty>
              {branchDiffSearchQuery.trim()
                ? t("git.noMatchingBranches")
                : t("git.noOtherBranches")}
            </CommandEmpty>
          ) : (
            <div className="space-y-1">
              {filteredBranchDiffBranches.map((branch) => (
                <CommandItemRow
                  key={branch}
                  type="button"
                  icon={<GitBranch size={14} className="text-subtle-foreground" />}
                  title={branch}
                  description={t("git.compareWithBranch", { branch: gitStatus.branch })}
                  onClick={() => void handleViewBranchDiff(branch)}
                  disabled={isLoadingBranchDiff}
                  className="min-h-9"
                />
              ))}
            </div>
          )}
        </CommandList>
      </GitCommandSurface>
      <GitCommandSurface
        isOpen={showStashList}
        onClose={() => {
          setShowStashList(false);
          setStashSearchQuery("");
        }}
        query={stashSearchQuery}
        onQueryChange={setStashSearchQuery}
        placeholder={t("git.searchStashes")}
        meta={t(stashes.length === 1 ? "git.stashCount" : "git.stashesCount", {
          count: stashes.length,
        })}
      >
        <CommandList>
          {filteredStashes.length === 0 ? (
            <CommandEmpty>
              {stashSearchQuery.trim() ? t("git.noMatchingStashes") : t("git.noStashes")}
            </CommandEmpty>
          ) : (
            filteredStashes.map((stash) => {
              const displayTitle = getStashDisplayTitle(stash.message);
              const isActionLoading = stashActionLoading.has(stash.index);

              return (
                <CommandItemRow
                  key={stash.index}
                  as="div"
                  icon={<Archive size={14} className="text-subtle-foreground" />}
                  title={displayTitle}
                  description={
                    <>
                      <span className="shrink-0">{formatRelativeDate(stash.date)}</span>
                      <CommandItemBadge>{getStashPositionLabel(stash.index)}</CommandItemBadge>
                    </>
                  }
                  contentLayout="inline"
                  disabled={isActionLoading}
                  className="group/stash min-h-9 text-subtle-foreground hover:text-foreground"
                  onClick={() => {
                    void handleViewStashDiff(stash.index);
                    setShowStashList(false);
                    setStashSearchQuery("");
                  }}
                  action={
                    <div className="ml-auto flex shrink-0 items-center gap-0.5 opacity-100 transition-opacity sm:opacity-0 sm:group-hover/stash:opacity-100 sm:group-focus-within/stash:opacity-100">
                      <Button
                        type="button"
                        onClick={(event) => {
                          event.stopPropagation();
                          void handleStashListAction(
                            () => applyStash(activeRepoPath!, stash.index),
                            stash.index,
                            t("git.applyStash"),
                          );
                        }}
                        disabled={isActionLoading}
                        variant="ghost"
                        size="icon-xs"
                        className="rounded-md text-subtle-foreground disabled:opacity-50"
                        tooltip={t("git.applyStash")}
                      >
                        <Download weight="fill" />
                      </Button>
                      <Button
                        type="button"
                        onClick={(event) => {
                          event.stopPropagation();
                          void handleStashListAction(
                            () => popStash(activeRepoPath!, stash.index),
                            stash.index,
                            t("git.popStash"),
                          );
                        }}
                        disabled={isActionLoading}
                        variant="ghost"
                        size="icon-xs"
                        className="rounded-md text-subtle-foreground disabled:opacity-50"
                        tooltip={t("git.popStash")}
                      >
                        <Upload />
                      </Button>
                      <Button
                        type="button"
                        onClick={(event) => {
                          event.stopPropagation();
                          void handleStashListAction(
                            () => dropStash(activeRepoPath!, stash.index),
                            stash.index,
                            t("git.dropStash"),
                          );
                        }}
                        disabled={isActionLoading}
                        variant="ghost"
                        size="icon-xs"
                        className="rounded-md text-destructive hover:bg-destructive/10 hover:text-destructive disabled:opacity-50"
                        tooltip={t("git.dropStash")}
                      >
                        <Trash2 />
                      </Button>
                    </div>
                  }
                />
              );
            })
          )}
        </CommandList>
      </GitCommandSurface>

      <GitRemoteManager
        isOpen={showRemoteManager}
        onClose={() => setShowRemoteManager(false)}
        repoPath={activeRepoPath}
        onRefresh={refreshAfterAction}
      />

      <GitTagManager
        isOpen={showTagManager}
        onClose={() => setShowTagManager(false)}
        repoPath={activeRepoPath}
        onRefresh={refreshAfterAction}
        onViewTagComparison={handleViewTagComparison}
      />
    </>
  );
};

export default memo(GitView);
