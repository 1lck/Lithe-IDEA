import { useCallback, useRef, useState } from "react";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { getBufferById } from "@/features/editor/utils/buffer-index";
import { useGitDiffPreferencesStore } from "../../stores/git-diff-preferences.store";
import { useTranslation } from "@/i18n/locale-provider";
import { Empty, EmptyDescription } from "@/ui/empty";
import type { MultiFileDiff } from "../../types/git-diff.types";
import {
  selectedCommitFileIndex,
  moveCommitFile,
  emptyDiffNavigation,
  commitDifferenceNavigation,
  type DiffNavigationState,
} from "../../utils/commit-file-diff-navigation";
import { getMultiDiffSectionKey } from "../../utils/multi-diff-search";
import { resolveDiffViewMode } from "../../utils/git-diff-split-layout";
import MonacoGitDiff, { type MonacoGitDiffHandle } from "./monaco-git-diff";
import { CommitFileDiffToolbar } from "./commit-file-diff-toolbar";
import { BinaryDiffViewer } from "./git-diff-binary";
import ImageDiffViewer from "./git-diff-image";
import { CommitFileDiffVersionHeader } from "./commit-file-diff-version-header";
import "./commit-file-diff-preview.css";

/** Git Log's repository preview renders one entry; the buffer owns its navigation snapshot. */
export default function CommitFileDiffPreview({ multiDiff }: { multiDiff: MultiFileDiff }) {
  // The landing intent belongs to this view and this exact navigation snapshot.
  const [firstDifferenceTarget, setFirstDifferenceTarget] = useState<MultiFileDiff | null>(null);
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
      startAtFirstDifference={firstDifferenceTarget === multiDiff}
      onTransition={(next, firstDifference) => setFirstDifferenceTarget(firstDifference ? next : null)}
      showWhitespace={showWhitespace}
      highlightWords={highlightWords}
      onWhitespace={() => setShowWhitespace((value) => !value)}
      onHighlightWords={() => setHighlightWords((value) => !value)}
    />
  );
}

function CommitFileDiffPage({ multiDiff, index, startAtFirstDifference, onTransition,
  showWhitespace, highlightWords, onWhitespace, onHighlightWords }: {
  multiDiff: MultiFileDiff;
  index: number;
  startAtFirstDifference: boolean;
  onTransition: (next: MultiFileDiff, firstDifference: boolean) => void;
  showWhitespace: boolean;
  highlightWords: boolean;
  onWhitespace: () => void;
  onHighlightWords: () => void;
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
  const onFile = (direction: -1 | 1, firstDifference = false) => {
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
      onTransition(next, firstDifference);
      state.actions.updateBufferContent(bufferId, "", false, next);
    }
  };
  const currentNavigation = diff?.is_image || diff?.is_binary
    ? { ...emptyDiffNavigation, ready: true }
    : navigation;
  const filePath = diff?.new_path || diff?.file_path || diff?.old_path || "";
  const fileName = filePath.split(/[\\/]/).pop() || filePath;
  const label = multiDiff.fileLabels?.[index] ?? multiDiff.commitHash;
  return (
    <div ref={appearanceRoot} className="commit-file-diff-preview monaco-editor-shell flex h-full min-h-0 flex-col overflow-hidden">
      <CommitFileDiffToolbar
        navigation={commitDifferenceNavigation(currentNavigation, index, multiDiff.files.length)}
        fileIndex={index}
        fileCount={multiDiff.files.length}
        viewMode={viewMode}
        canSplit={Boolean(diff && !diff.is_new && !diff.is_deleted)}
        showWhitespace={showWhitespace}
        onWhitespace={onWhitespace}
        highlightWords={highlightWords}
        onHighlightWords={onHighlightWords}
        canHighlightWords={Boolean(diff && !diff.is_image && !diff.is_binary)}
        onDifference={(direction) => {
          if (direction === "next" && currentNavigation.ready && !currentNavigation.canNext)
            onFile(1, true);
          else editor.current?.navigateDifference(direction);
        }}
        onSource={() => editor.current?.jumpToSource()}
        onFile={(direction) => onFile(direction)}
        onViewMode={setViewMode}
      />
      {diff && (
        <CommitFileDiffVersionHeader diff={diff} revisions={multiDiff.fileRevisions?.[index]}
          label={label} viewMode={viewMode} />
      )}
      <div className="min-h-0 flex-1 overflow-hidden">
        {!diff ? (
          <Empty className="h-full rounded-none">
            <EmptyDescription>{t("git.noDiffData")}</EmptyDescription>
          </Empty>
        ) : diff.is_image ? (
          <ImageDiffViewer diff={diff} fileName={fileName} onClose={() => {}} />
        ) : diff.is_binary ? (
          <BinaryDiffViewer fileName={fileName} />
        ) : (
          <MonacoGitDiff
            ref={editor}
            diff={diff}
            viewMode={viewMode}
            showWhitespace={showWhitespace}
            sourceRepoPath={multiDiff.repoPath}
            onNavigationChange={onNavigationChange}
            startAtFirstDifference={startAtFirstDifference}
            highlightWords={highlightWords}
            repositoryPreview
            onSplitLayout={onSplitLayout}
          />
        )}
      </div>
    </div>
  );
}
