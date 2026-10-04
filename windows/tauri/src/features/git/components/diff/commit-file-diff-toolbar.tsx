import { Button } from "@/ui/button";
import {
  ArrowUpIcon,
  ArrowDownIcon,
  ArrowLeftIcon,
  ArrowRightIcon,
  PencilLineIcon,
  ColumnsIcon,
  RowsIcon,
} from "@/ui/icons";
import { useTranslation } from "@/i18n/locale-provider";
import type { DiffNavigationState } from "../../utils/commit-file-diff-navigation";

interface Props {
  navigation: DiffNavigationState;
  fileIndex: number;
  fileCount: number;
  viewMode: "split" | "unified";
  canSplit: boolean;
  showWhitespace: boolean;
  onDifference: (direction: "previous" | "next") => void;
  onFile: (direction: -1 | 1) => void;
  onSource: () => void;
  onViewMode: (mode: "split" | "unified") => void;
  onWhitespace: () => void;
  highlightWords: boolean;
  canHighlightWords: boolean;
  onHighlightWords: () => void;
}

export function CommitFileDiffToolbar(props: Props) {
  const { t } = useTranslation();
  const { navigation, fileIndex, fileCount } = props;
  return (
    <div
      role="toolbar"
      aria-label={t("git.diff.repositoryPreviewEmptyTitle")}
      className="commit-diff-toolbar flex shrink-0 items-center gap-1"
    >
      <Button
        variant="ghost"
        size="icon-xs"
        tooltip={t("git.diff.previousDifference")}
        disabled={!navigation.canPrevious}
        onClick={() => props.onDifference("previous")}
      >
        <ArrowUpIcon className="size-4" />
      </Button>
      <Button
        variant="ghost"
        size="icon-xs"
        tooltip={t("git.diff.nextDifference")}
        disabled={!navigation.canNext}
        onClick={() => props.onDifference("next")}
      >
        <ArrowDownIcon className="size-4" />
      </Button>
      <span className="mx-1 h-4 border-l border-border" />
      <Button
        variant="ghost"
        size="icon-xs"
        tooltip={t("git.jumpToSource")}
        disabled={!navigation.canJumpToSource}
        onClick={props.onSource}
      >
        <PencilLineIcon className="size-4" />
      </Button>
      <span className="mx-1 h-4 border-l border-border" />
      <Button
        variant="ghost"
        size="icon-xs"
        tooltip={t("git.diff.previousFile")}
        disabled={fileIndex <= 0}
        onClick={() => props.onFile(-1)}
      >
        <ArrowLeftIcon className="size-4" />
      </Button>
      <Button
        variant="ghost"
        size="icon-xs"
        tooltip={t("git.diff.nextFile")}
        disabled={fileIndex < 0 || fileIndex >= fileCount - 1}
        onClick={() => props.onFile(1)}
      >
        <ArrowRightIcon className="size-4" />
      </Button>
      <span className="ui-text-xs truncate text-muted-foreground" aria-live="polite">
        {t("git.diff.filePosition", { current: Math.max(0, fileIndex + 1), total: fileCount })}
      </span>
      <div className="flex-1" />
      <Button variant="ghost" size="xs" active={props.highlightWords} aria-pressed={props.highlightWords}
        disabled={!props.canHighlightWords} onClick={props.onHighlightWords}>
        {t("git.diff.highlightWords")}
      </Button>
      <Button variant="ghost" size="xs" active={props.showWhitespace} aria-pressed={props.showWhitespace} onClick={props.onWhitespace}>
        {t(props.showWhitespace ? "git.diff.hideWhitespace" : "git.diff.showWhitespace")}
      </Button>
      <Button
        variant="ghost"
        size="icon-xs"
        tooltip={t("git.diff.unified")}
        active={props.viewMode === "unified"}
        aria-pressed={props.viewMode === "unified"}
        onClick={() => props.onViewMode("unified")}
      >
        <RowsIcon className="size-4" />
      </Button>
      <Button
        variant="ghost"
        size="icon-xs"
        tooltip={t("git.diff.split")}
        disabled={!props.canSplit}
        active={props.viewMode === "split"}
        aria-pressed={props.viewMode === "split"}
        onClick={() => props.onViewMode("split")}
      >
        <ColumnsIcon className="size-4" />
      </Button>
    </div>
  );
}
