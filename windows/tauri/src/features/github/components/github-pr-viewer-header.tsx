import { DotsThreeIcon as MoreHorizontal } from "@/ui/icons";
import { Button } from "@/ui/button";
import { useTranslation } from "@/i18n/locale-provider";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/ui/dropdown";
import Tooltip from "@/ui/tooltip";
import type { PullRequestDetails } from "../types/github.types";
import { GitHubViewerHeader } from "./github-viewer-shell";

interface GitHubPRViewerHeaderProps {
  pr: PullRequestDetails;
  activeView: "activity" | "files";
  changedFilesCount: number;
  additions: number;
  deletions: number;
  isRefreshingDetails: boolean;
  onRefresh: () => void;
  onCheckout: () => void;
  onOpenInBrowser: () => void;
  onCopyPRLink: () => void;
  onCopyBranchName: () => void;
  onToggleFilesView: () => void;
  onComment: () => void;
  onApprove: () => void;
  onRequestChanges: () => void;
  onMerge: () => void;
  onClosePR: () => void;
}

export function GitHubPRViewerHeader({
  pr,
  activeView,
  changedFilesCount,
  additions,
  deletions,
  isRefreshingDetails,
  onRefresh,
  onCheckout,
  onOpenInBrowser,
  onCopyPRLink,
  onCopyBranchName,
  onToggleFilesView,
  onComment,
  onApprove,
  onRequestChanges,
  onMerge,
  onClosePR,
}: GitHubPRViewerHeaderProps) {
  const { t } = useTranslation();
  const isClosed = pr.state === "closed";
  const canMerge = !isClosed && !pr.isDraft && pr.mergeable !== "CONFLICTING";

  return (
    <GitHubViewerHeader
      title={
        <span className="flex min-w-0 items-center gap-2">
          <span className="shrink-0 text-subtle-foreground">{`PR #${pr.number}`}</span>
          <span className="text-subtle-foreground/60">&rsaquo;</span>
          <span className="min-w-0 truncate">{pr.title}</span>
          <span className="ml-1 hidden shrink-0 items-center gap-1.5 font-mono sm:inline-flex">
            <span className="text-git-added">+{additions}</span>
            <span className="text-git-deleted">-{deletions}</span>
          </span>
        </span>
      }
      actions={
        <DropdownMenu>
          <Tooltip content={t("github.pullRequestActions")} side="bottom">
            <DropdownMenuTrigger
              render={
                <Button
                  type="button"
                  variant="ghost"
                  size="icon-xs"
                  aria-label={t("github.pullRequestActions")}
                />
              }
            >
              <MoreHorizontal />
            </DropdownMenuTrigger>
          </Tooltip>
          <DropdownMenuContent>
            <DropdownMenuItem disabled={isRefreshingDetails} onClick={onRefresh}>
              {isRefreshingDetails ? t("github.refreshing") : t("github.refresh")}
            </DropdownMenuItem>
            <DropdownMenuItem onClick={onCheckout}>{t("github.checkoutBranch")}</DropdownMenuItem>
            <DropdownMenuItem disabled={isClosed} onClick={onApprove}>
              {t("github.approve")}
            </DropdownMenuItem>
            <DropdownMenuItem disabled={isClosed} onClick={onRequestChanges}>
              {t("github.requestChanges")}
            </DropdownMenuItem>
            <DropdownMenuItem disabled={isClosed} onClick={onClosePR}>
              {t("github.closePullRequest")}
            </DropdownMenuItem>
            <DropdownMenuItem onClick={onOpenInBrowser}>{t("github.openOnGitHub")}</DropdownMenuItem>
            <DropdownMenuItem onClick={onCopyPRLink}>{t("github.copyLink")}</DropdownMenuItem>
            <DropdownMenuItem onClick={onCopyBranchName}>{t("github.copyBranchName")}</DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      }
    >
      <div className="flex min-w-0 flex-wrap items-center justify-between gap-2">
        <div className="flex items-center gap-1 rounded-lg bg-surface/60 p-0.5">
          <Button
            type="button"
            onClick={activeView === "files" ? onToggleFilesView : undefined}
            variant="ghost"
            active={activeView === "activity"}
            size="xs"
          >
            {t("github.overview")}
          </Button>
          <Button
            type="button"
            onClick={activeView === "activity" ? onToggleFilesView : undefined}
            variant="ghost"
            active={activeView === "files"}
            size="xs"
          >
            {t("github.filesCount", { count: changedFilesCount })}
          </Button>
        </div>
        <div className="flex items-center gap-1">
          <Button onClick={onComment} disabled={isClosed} variant="ghost" size="xs">
            {t("github.comment")}
          </Button>
          <Button onClick={onMerge} disabled={!canMerge} variant="accent" size="xs">
            {t("github.merge")}
          </Button>
        </div>
      </div>
    </GitHubViewerHeader>
  );
}
