import GitBranchManager from "@/features/git/components/git-branch-manager";
import { useGitStore } from "@/features/git/stores/git.store";
import { useRepositoryStore } from "@/features/git/stores/git-repository.store";
import { openGitWorktreeWorkspace } from "@/features/git/utils/git-worktree-open";
import type { FooterLeadingItemId } from "@/features/layout/config/item-order";
import type { ChromeItem } from "@/features/layout/utils/chrome-items";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { useTranslation } from "@/i18n/locale-provider";

export function useFooterGitBranchItem(): ChromeItem<FooterLeadingItemId> | null {
  const { t } = useTranslation();
  const rootFolderPath = useFileSystemStore.use.rootFolderPath?.();
  const activeRepoPath = useRepositoryStore.use.activeRepoPath();
  const repositoryStatuses = useGitStore((state) => state.repositoryStatuses);
  const availableRepoPaths = useRepositoryStore((state) => state.availableRepoPaths);
  const currentWorkspaceRepoPath = useGitStore((state) => state.currentWorkspaceRepoPath);
  const actions = useGitStore((state) => state.actions);
  const footerRepoPath = activeRepoPath ?? currentWorkspaceRepoPath ?? rootFolderPath;
  const footerGitStatus = footerRepoPath ? repositoryStatuses[footerRepoPath] : null;
  const footerBranch = footerGitStatus?.branch;

  if (!footerRepoPath || !footerBranch) return null;

  return {
    id: "branch",
    label: t("footer.gitBranch"),
    content: (
      <GitBranchManager
        currentBranch={footerBranch}
        ahead={footerGitStatus.ahead}
        behind={footerGitStatus.behind}
        repoPath={footerRepoPath}
        paletteTarget
        triggerSurface="toolbar"
        onBranchChange={async () => {
          await actions.refreshRepositoryStatuses(
            [...availableRepoPaths, footerRepoPath],
            availableRepoPaths,
          );
        }}
        onWorktreeChange={async (worktreePath) => {
          const opened = await openGitWorktreeWorkspace(worktreePath);
          if (!opened) return;
        }}
        onRepositoryChange={async (repoPath) => {
          if (!repoPath) return;

          await actions.refreshRepositoryStatuses(
            [...availableRepoPaths, repoPath],
            availableRepoPaths,
          );
        }}
      />
    ),
  };
}
