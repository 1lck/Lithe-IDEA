import { useCallback, useRef, useState } from "react";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { getBufferById } from "@/features/editor/utils/buffer-index";
import { useGitDiffPreferencesStore } from "../../stores/git-diff-preferences.store";
import { useTranslation } from "@/i18n/locale-provider";
import { Empty, EmptyDescription } from "@/ui/empty";
import type { MultiFileDiff } from "../../types/git-diff.types";
import {
  selectedCommitFileIndex,
  commitPreviewFilePosition,
  moveCommitFile,
  emptyDiffNavigation,
  commitDifferenceNavigation,
  type DiffNavigationState,
} from "../../utils/commit-file-diff-navigation";
import { getMultiDiffSectionKey } from "../../utils/multi-diff-search";
import { resolveDiffViewMode } from "../../utils/git-diff-split-layout";
import MonacoGitDiff, { type MonacoGitDiffHandle } from "./monaco-git-diff";
import IndependentCommitDiff from "./independent-commit-diff";
import { CommitFileDiffToolbar } from "./commit-file-diff-toolbar";
import { BinaryDiffViewer } from "./git-diff-binary";
import ImageDiffViewer from "./git-diff-image";
import { CommitFileDiffVersionHeader } from "./commit-file-diff-version-header";
import { useCommitDiffReview } from "../../hooks/use-commit-diff-review";
import type { CommitDiffBlockControls } from "./commit-diff-block-controls";
import { Spinner } from "@/ui/spinner";
import "./commit-file-diff-preview.css";

/** Git Log's repository preview renders one entry; the buffer owns its navigation snapshot. */
export default function CommitFileDiffPreview({ multiDiff, review }: {
  multiDiff: MultiFileDiff; review?: ReturnType<typeof useCommitDiffReview>;
}) {
  const [showWhitespace, setShowWhitespace] = useState(false);
  const [highlightWords, setHighlightWords] = useState(true);
  const index = selectedCommitFileIndex(multiDiff);
  const diff = multiDiff.files[index];
  const key = diff ? getMultiDiffSectionKey(multiDiff, diff, index) : "empty";
  return (
    <CommitFileDiffPage
      key={`${multiDiff.repoPath}:${multiDiff.commitHash}:${key}`}
      multiDiff={multiDiff}
      index={index}
      showWhitespace={showWhitespace}
      highlightWords={highlightWords}
      onWhitespace={() => setShowWhitespace((value) => !value)}
      onHighlightWords={() => setHighlightWords((value) => !value)}
      review={review}
    />
  );
}

/** Worktree refresh and index writes have a separate owner from immutable
 * history. Both hosts use exactly the same single-file presentation. */
export function WorkingTreeCommitDiff({ multiDiff }: { multiDiff: MultiFileDiff }) {
  const bufferId = useBufferStore(state => state.activeBufferId);
  const index = selectedCommitFileIndex(multiDiff);
  const diff = multiDiff.files[index];
  const key = diff ? getMultiDiffSectionKey(multiDiff, diff, index) : multiDiff.initiallyExpandedFileKey ?? "";
  const review = useCommitDiffReview(bufferId, key,
    multiDiff.isLoading ? undefined : multiDiff.workingTreeTargets?.[key],
    !multiDiff.isLoading && multiDiff.repoPath && diff && multiDiff.files.length === 1 ? {
      repoPath: multiDiff.repoPath,
      filePath: /^(?:staged|unstaged):/.test(key) ? key.replace(/^(?:staged|unstaged):/, "") : diff.file_path,
      untracked: diff.is_new,
      ...(key.startsWith("staged:") ? { staged: true } : {}),
    } : undefined);
  return <CommitFileDiffPreview multiDiff={multiDiff} review={review} />;
}

function CommitFileDiffPage({ multiDiff, index,
  showWhitespace, highlightWords, onWhitespace, onHighlightWords, review }: {
  multiDiff: MultiFileDiff;
  index: number;
  showWhitespace: boolean;
  highlightWords: boolean;
  onWhitespace: () => void;
  onHighlightWords: () => void;
  review?: ReturnType<typeof useCommitDiffReview>;
}) {
  const { t } = useTranslation();
  const bufferId = useBufferStore((state) => state.activeBufferId);
  const editor = useRef<MonacoGitDiffHandle>(null);
  const appearanceRoot = useRef<HTMLDivElement>(null);
  const [navigation, setNavigation] = useState(emptyDiffNavigation);
  const onSplitLayout = useCallback((width: number) => {
    // Sash events update only this view's CSS; never publish drag frames to React/the buffer.
    appearanceRoot.current?.style.setProperty("--commit-diff-left-width", `${width}px`);
  }, []);
  const preferredMode = useGitDiffPreferencesStore.use.viewMode();
  const setViewMode = useGitDiffPreferencesStore.use.actions().setViewMode;
  const diff = multiDiff.files[index];
  const initialDiff = useRef(diff);
  const filePosition = commitPreviewFilePosition(multiDiff);
  const viewMode = diff ? resolveDiffViewMode(diff, preferredMode) : preferredMode;
  const onNavigationChange = useCallback((next: DiffNavigationState) => {
    setNavigation((previous) =>
      previous.count === next.count &&
      previous.ready === next.ready &&
      previous.canNext === next.canNext &&
      previous.canPrevious === next.canPrevious &&
      previous.canJumpToSource === next.canJumpToSource
        ? previous
        : next,
    );
  }, []);
  const onFile = (direction: -1 | 1) => {
    if (review && multiDiff.workingTreeFileOrder?.length) {
      void review.navigateFile(direction);
      return;
    }
    const state = useBufferStore.getState();
    const current = getBufferById(state.buffers, bufferId);
    // A replaced preview or inactive tab cannot receive a delayed navigation action.
    if (
      !bufferId ||
      state.activeBufferId !== bufferId ||
      current?.type !== "diff" ||
      current.diffData !== multiDiff
    )
      return;
    const next = moveCommitFile(multiDiff, direction);
    if (next) {
      state.actions.updateBufferContent(bufferId, "", false, next);
    }
  };
  const currentNavigation = review?.fileNavigationBusy ? emptyDiffNavigation : diff?.is_image || diff?.is_binary
    ? { ...emptyDiffNavigation, ready: true }
    : navigation;
  const filePath = diff?.new_path || diff?.file_path || diff?.old_path || "";
  const fileName = filePath.split(/[\\/]/).pop() || filePath;
  const label = multiDiff.fileLabels?.[index] ?? multiDiff.commitHash;
  const blockControls: CommitDiffBlockControls | undefined = review ? {
    blocks: review.blocks, disabled: review.busy || !review.snapshot || review.error === "read",
    includeTitle: t("git.diff.includeBlock"), excludeTitle: t("git.diff.excludeBlock"),
    rollbackTitle: t("git.diff.rollbackHunk"),
    onToggle: (id, included) => { void review.toggle(id, included); },
    onRollback: id => { void review.rollback(id); },
  } : undefined;
  return (
    <div ref={appearanceRoot} className="commit-file-diff-preview monaco-editor-shell flex h-full min-h-0 flex-col overflow-hidden">
      <CommitFileDiffToolbar
        navigation={commitDifferenceNavigation(currentNavigation, filePosition.index, filePosition.count)}
        fileIndex={filePosition.index}
        fileCount={filePosition.count}
        fileNavigationBusy={multiDiff.isLoading || review?.fileNavigationBusy}
        viewMode={viewMode}
        canSplit={Boolean(diff && !diff.is_new && !diff.is_deleted)}
        showWhitespace={showWhitespace}
        onWhitespace={onWhitespace}
        highlightWords={highlightWords}
        onHighlightWords={onHighlightWords}
        canHighlightWords={Boolean(diff && !diff.is_image && !diff.is_binary)}
        onDifference={(direction) => {
          if (direction === "next" && currentNavigation.ready && !currentNavigation.canNext)
            onFile(1);
          else editor.current?.navigateDifference(direction);
        }}
        onSource={() => editor.current?.jumpToSource()}
        onFile={(direction) => onFile(direction)}
        onViewMode={setViewMode}
        onRefresh={review ? () => { void review.refresh(); } : undefined}
        refreshing={review?.busy}
        includedCount={review?.blocks.filter(block => block.checked || block.indeterminate).length}
      />
      {diff && (
        <CommitFileDiffVersionHeader diff={diff} revisions={multiDiff.fileRevisions?.[index]}
          label={label} viewMode={viewMode} workingTree={review ? {
            staged: review.presentation?.staged === true,
            included: review.presentation?.included === true,
            indeterminate: review.presentation?.indeterminate === true,
            disabled: review.busy || !review.snapshot,
            onToggle: included => { void review.toggle(null, included); },
          } : undefined} />
      )}
      {review?.error && <div role="alert" className="px-3 py-1 text-xs text-destructive">
        {t(review.error === "read" ? "git.diff.refreshFailed" : review.error === "stale"
          ? "git.diff.selectionChanged" : "git.diff.stageFailed")}
      </div>}
      <div className="min-h-0 flex-1 overflow-hidden">
        {!diff ? (
          <Empty className="h-full rounded-none">
            <EmptyDescription>{multiDiff.isLoading ? <Spinner label={t("git.loadingDiff")} showLabel /> : t("git.noDiffData")}</EmptyDescription>
          </Empty>
        ) : diff.is_image ? (
          <ImageDiffViewer diff={diff} fileName={fileName} onClose={() => {}} />
        ) : diff.is_binary ? (
          <BinaryDiffViewer fileName={fileName} />
        ) : viewMode === "split" || diff.is_new ? (
          <IndependentCommitDiff ref={editor} diff={diff} sourceRepoPath={multiDiff.repoPath}
            showWhitespace={showWhitespace} highlightWords={highlightWords}
            startAtFirstDifference={!review || initialDiff.current === diff} onNavigationChange={onNavigationChange}
            blockControls={blockControls}
            onSplitLayout={onSplitLayout} />
        ) : (
          <MonacoGitDiff
            ref={editor}
            diff={diff}
            viewMode={viewMode}
            showWhitespace={showWhitespace}
            sourceRepoPath={multiDiff.repoPath}
            onNavigationChange={onNavigationChange}
            startAtFirstDifference={!review || initialDiff.current === diff}
            highlightWords={highlightWords}
            repositoryPreview
            blockControls={blockControls}
            onSplitLayout={onSplitLayout}
          />
        )}
      </div>
    </div>
  );
}
