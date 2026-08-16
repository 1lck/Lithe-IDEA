import {
  ArrowClockwiseIcon as Refresh,
  CopyIcon as Copy,
  GitBranchIcon,
  GitDiffIcon as GitDiff,
  MinusIcon,
} from "@/ui/icons";
import { Button } from "@/ui/button";

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
  return (
    <div className="shrink-0 border-border border-b bg-surface font-sans ui-text-sm">
      <div className="flex h-8 items-center gap-2 px-2">
        <GitBranchIcon className="size-3.5 text-subtle-foreground" />
        <span className="font-medium">Git</span>
        <button
          type="button"
          onClick={onShowAll}
          className="h-6 max-w-60 truncate rounded border border-border-strong/60 bg-background px-2 text-left font-medium hover:bg-accent"
          title="Show all references"
        >
          Log: {referenceName}
        </button>
        <Button
          type="button"
          variant="ghost"
          size="icon-xs"
          onClick={onRefresh}
          disabled={isRefreshing}
          tooltip="Refresh Git log"
          aria-label="Refresh Git log"
        >
          <Refresh className={isRefreshing ? "animate-spin" : undefined} />
        </Button>
        <span className="ml-auto text-subtle-foreground">Read-only</span>
        <Button
          type="button"
          variant="ghost"
          size="icon-xs"
          onClick={onClose}
          tooltip="Hide Git Log"
          aria-label="Hide Git Log"
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
          Open Diff
        </Button>
        <Button
          type="button"
          variant="ghost"
          size="xs"
          disabled={!canCompareWithHead || isComparing}
          onClick={onCompareWithHead}
        >
          <GitBranchIcon />
          Compare with HEAD
        </Button>
        <Button
          type="button"
          variant="ghost"
          size="xs"
          disabled={!hasSelectedCommit}
          onClick={onCopyHash}
        >
          <Copy />
          Copy Hash
        </Button>
      </div>
    </div>
  );
}
