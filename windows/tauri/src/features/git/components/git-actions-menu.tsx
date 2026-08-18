import {
  ArchiveIcon as Archive,
  DownloadIcon as Download,
  GitBranchIcon as GitBranch,
  FolderOpenIcon as FolderOpen,
  GitPullRequestIcon as GitPullRequest,
  ArrowClockwiseIcon as RefreshCw,
  ArrowCounterClockwiseIcon as RotateCcw,
  HardDrivesIcon as Server,
  GearSixIcon as Settings,
  TagIcon as Tag,
  UploadIcon as Upload,
} from "@/ui/icons";
import { useState } from "react";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { Dropdown, type MenuItem } from "@/ui/dropdown";
import { Spinner } from "@/ui/spinner";
import { showConfirmDialog } from "@/ui/dialog";
import { toast } from "sonner";
import { useTranslation } from "@/i18n/locale-provider";
import { fetchChanges, pushChanges, type GitRemoteActionResult } from "../api/git-remotes-api";
import { discardAllChanges, initRepository } from "../api/git-status-api";
import { useGitStore } from "../stores/git.store";
import { type GitActionsMenuAnchorRect } from "../utils/git-actions-menu-position";

interface GitActionsMenuProps {
  isOpen: boolean;
  anchorRect: GitActionsMenuAnchorRect | null;
  onClose: () => void;
  hasGitRepo: boolean;
  repoPath?: string;
  onRefresh?: () => void;
  onPull?: () => Promise<unknown> | void;
  isPulling?: boolean;
  onOpenBranchManager?: () => void;
  onShowBranchDiff?: () => void;
  onOpenRemoteManager?: () => void;
  onOpenTagManager?: () => void;
  onViewStashes?: () => void;
  onSelectRepository?: () => Promise<void> | void;
  isSelectingRepository?: boolean;
  onInitializeRepository?: () => Promise<void> | void;
  isInitializingRepository?: boolean;
}

const GitActionsMenu = ({
  isOpen,
  anchorRect,
  onClose,
  hasGitRepo,
  repoPath,
  onRefresh,
  onPull,
  isPulling = false,
  onOpenBranchManager,
  onShowBranchDiff,
  onOpenRemoteManager,
  onOpenTagManager,
  onViewStashes,
  onSelectRepository,
  isSelectingRepository,
  onInitializeRepository,
  isInitializingRepository,
}: GitActionsMenuProps) => {
  const { t } = useTranslation();
  const [isLoading, setIsLoading] = useState(false);
  const isRefreshing = useGitStore((state) => state.isRefreshing);
  const confirmBeforeDiscard = useSettingsStore((state) => state.settings.confirmBeforeDiscard);

  const handleAction = async (
    action: () => Promise<boolean | GitRemoteActionResult>,
    actionName: string,
    messages?: {
      loading?: string;
      success?: string;
      error?: string;
    },
  ) => {
    if (!repoPath) return;

    let toastId: string | number | null = null;
    setIsLoading(true);
    try {
      if (messages?.loading) {
        toastId = toast.info(messages.loading, {
          duration: 0,
        });
      }

      const result = await action();
      const remoteResult =
        typeof result === "boolean" ? { success: result, error: undefined } : result;

      if (remoteResult.success) {
        if (toastId) toast.dismiss(toastId);
        toast.success(messages?.success ?? `${actionName} completed.`);
        onRefresh?.();
      } else {
        const errorMessage = remoteResult.error || messages?.error || `${actionName} failed.`;
        if (toastId) toast.dismiss(toastId);
        toast.error(errorMessage);
        console.error(`${actionName} failed`, remoteResult.error);
      }
    } catch (error) {
      const errorMessage =
        error instanceof Error ? error.message : messages?.error || `${actionName} failed.`;
      if (toastId) toast.dismiss(toastId);
      toast.error(errorMessage);
      console.error(`${actionName} error:`, error);
    } finally {
      setIsLoading(false);
    }
  };

  const handlePush = () => {
    handleAction(() => pushChanges(repoPath!), t("git.push"), {
      loading: t("git.pushingChanges"),
      success: t("git.changesPushed"),
      error: t("git.pushFailed"),
    });
  };

  const handlePull = () => {
    void onPull?.();
    onClose();
  };

  const handleFetch = () => {
    handleAction(() => fetchChanges(repoPath!), t("git.fetch"), {
      loading: t("git.fetchingChanges"),
      success: t("git.changesFetched"),
      error: t("git.fetchFailed"),
    });
  };

  const handleDiscardAllChanges = async () => {
    if (!repoPath) return;
    if (
      confirmBeforeDiscard &&
      !(await showConfirmDialog(t("git.discardChangesConfirm"), {
        title: t("git.discardChanges"),
        confirmLabel: t("git.discard"),
      }))
    ) {
      return;
    }
    handleAction(() => discardAllChanges(repoPath!), t("git.discardAllChanges"));
  };

  const handleInitRepository = () => {
    if (onInitializeRepository) {
      void onInitializeRepository();
      onClose();
      return;
    }

    handleAction(() => initRepository(repoPath!), t("git.initializeRepository"));
  };

  const handleRefresh = async () => {
    await onRefresh?.();
  };

  const handleRemoteManager = () => {
    onOpenRemoteManager?.();
    onClose();
  };

  const handleBranchManager = () => {
    onOpenBranchManager?.();
    onClose();
  };

  const handleShowBranchDiff = () => {
    onShowBranchDiff?.();
    onClose();
  };

  const handleTagManager = () => {
    onOpenTagManager?.();
    onClose();
  };

  const handleViewStashes = () => {
    onViewStashes?.();
    onClose();
  };

  const handleSelectRepository = async () => {
    await onSelectRepository?.();
    onClose();
  };

  if (!isOpen || !anchorRect) {
    return null;
  }

  const items: MenuItem[] = hasGitRepo
    ? [
        {
          id: "select-repository",
          label: isSelectingRepository ? t("git.selecting") : t("git.selectRepository"),
          icon: <FolderOpen />,
          disabled: isSelectingRepository,
          onClick: () => void handleSelectRepository(),
        },
        { id: "sep-1", label: "", separator: true, onClick: () => {} },
        {
          id: "manage-branches",
          label: t("git.manageBranches"),
          icon: <GitBranch />,
          onClick: handleBranchManager,
        },
        {
          id: "show-branch-diff",
          label: t("git.showBranchDiff"),
          icon: <GitPullRequest />,
          onClick: handleShowBranchDiff,
        },
        { id: "sep-branches", label: "", separator: true, onClick: () => {} },
        {
          id: "push",
          label: t("git.pushChanges"),
          icon: <Upload />,
          disabled: isLoading || isPulling,
          onClick: handlePush,
        },
        { id: "sep-2", label: "", separator: true, onClick: () => {} },
        {
          id: "pull",
          label: t("git.pullChanges"),
          icon: <Download weight="fill" />,
          disabled: isLoading || isPulling,
          onClick: handlePull,
        },
        {
          id: "fetch",
          label: t("git.fetch"),
          icon: <GitPullRequest />,
          disabled: isLoading || isPulling,
          onClick: handleFetch,
        },
        { id: "sep-3", label: "", separator: true, onClick: () => {} },
        {
          id: "manage-remotes",
          label: t("git.manageRemotes"),
          icon: <Server />,
          onClick: handleRemoteManager,
        },
        {
          id: "manage-tags",
          label: t("git.manageTags"),
          icon: <Tag />,
          onClick: handleTagManager,
        },
        {
          id: "view-stashes",
          label: t("git.viewStashes"),
          icon: <Archive />,
          onClick: handleViewStashes,
        },
        { id: "sep-4", label: "", separator: true, onClick: () => {} },
        {
          id: "refresh",
          label: t("git.refreshStatus"),
          icon: isRefreshing ? <Spinner label={t("git.refreshStatus")} compact /> : <RefreshCw />,
          disabled: isRefreshing,
          onClick: () => void handleRefresh(),
        },
        { id: "sep-5", label: "", separator: true, onClick: () => {} },
        {
          id: "discard-all",
          label: t("git.discardAllChanges"),
          icon: <RotateCcw />,
          disabled: isLoading,
          className: "text-destructive",
          onClick: () => void handleDiscardAllChanges(),
        },
      ]
    : [
        {
          id: "init-repository",
          label: isInitializingRepository
            ? t("git.initializing")
            : t("git.initializeRepository"),
          icon: <Settings />,
          disabled: isLoading || isInitializingRepository,
          onClick: handleInitRepository,
        },
        { id: "sep-1", label: "", separator: true, onClick: () => {} },
        {
          id: "refresh",
          label: t("git.refreshStatus"),
          icon: isRefreshing ? <Spinner label={t("git.refreshStatus")} compact /> : <RefreshCw />,
          disabled: isRefreshing,
          onClick: () => void handleRefresh(),
        },
      ];

  return (
    <Dropdown
      isOpen={isOpen}
      point={{
        x: anchorRect.right,
        y: anchorRect.bottom + 6,
      }}
      items={items}
      onClose={onClose}
    />
  );
};

export default GitActionsMenu;
