import {
  ArrowClockwiseIcon as Refresh,
  CopyIcon as Copy,
  GitBranchIcon,
  GitDiffIcon as GitDiff,
  MinusIcon,
} from "@/ui/icons";
import { Button } from "@/ui/button";
import { useTranslation } from "@/i18n/locale-provider";

export function GitLogTitleBar({
  referenceName,
  isRefreshing,
  isOpeningDiff,
  isComparing,
  hasSelectedCommit,
  canCompareWithHead,
  onShowAll,
  onRefresh,
  onOpenDiff,
  onCompareWithHead,
  onCopyHash,
  onClose,
}: {
  referenceName: string;
  isRefreshing: boolean;
  isOpeningDiff: boolean;
  isComparing: boolean;
  hasSelectedCommit: boolean;
  canCompareWithHead: boolean;
  onShowAll: () => void;
  onRefresh: () => void;
  onOpenDiff: () => void;
  onCompareWithHead: () => void;
  onCopyHash: () => void;
  onClose: () => void;
}) {
  const { t } = useTranslation();

  return (
    <div className="shrink-0 border-border border-b bg-surface font-sans ui-text-sm">
      <div className="flex h-8 items-center gap-2 px-2">
        <GitBranchIcon className="size-3.5 text-subtle-foreground" />
        <span className="font-medium">{t("workbench.gitLog")}</span>
        <button
          type="button"
          onClick={onShowAll}
          className="h-6 max-w-60 truncate rounded border border-border-strong/60 bg-background px-2 text-left font-medium hover:bg-accent"
          title={t("git.log.showAll")}
        >
          {t("git.log.logLabel", { name: referenceName })}
        </button>
        <Button
          type="button"
          variant="ghost"
          size="icon-xs"
          onClick={onRefresh}
          disabled={isRefreshing}
          tooltip={t("git.log.refresh")}
          aria-label={t("git.log.refresh")}
        >
          <Refresh className={isRefreshing ? "animate-spin" : undefined} />
        </Button>
        <span className="ml-auto text-subtle-foreground">{t("footer.readOnly")}</span>
        <Button
          type="button"
          variant="ghost"
          size="icon-xs"
          onClick={onClose}
          tooltip={t("git.log.hide")}
          aria-label={t("git.log.hide")}
        >
          <MinusIcon />
        </Button>
      </div>
      <div className="flex h-8 items-center gap-1 border-border border-t px-2">
        <Button
          type="button"
          variant="ghost"
          size="xs"
          disabled={!hasSelectedCommit || isOpeningDiff}
          onClick={onOpenDiff}
        >
          <GitDiff />
          {t("git.log.openDiff")}
        </Button>
        <Button
          type="button"
          variant="ghost"
          size="xs"
          disabled={!canCompareWithHead || isComparing}
          onClick={onCompareWithHead}
        >
          <GitBranchIcon />
          {t("git.log.compareWithHead")}
        </Button>
        <Button
          type="button"
          variant="ghost"
          size="xs"
          disabled={!hasSelectedCommit}
          onClick={onCopyHash}
        >
          <Copy />
          {t("git.log.copyHash")}
        </Button>
      </div>
    </div>
  );
}
