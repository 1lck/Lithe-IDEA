import { useVirtualizer } from "@tanstack/react-virtual";
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef } from "react";
import {
  ContextMenu,
  ContextMenuContent,
  ContextMenuItem,
  ContextMenuSeparator,
  ContextMenuShortcut,
  ContextMenuTrigger,
} from "@/ui/context-menu";
import { bindScrollContainerWheel } from "@/ui/scroll-container-wheel";
import {
  ArrowBendDownLeftIcon as Revert,
  ArrowCounterClockwiseIcon as Reset,
  ArrowsInLineVerticalIcon,
  CopyIcon as Copy,
  EyeIcon as Eye,
  EyeSlashIcon as EyeSlash,
  GitBranchIcon as GitBranch,
  GitCommitIcon as CherryPick,
  GitDiffIcon as GitDiff,
  GitMergeIcon as Squash,
  MagnifyingGlassIcon as Search,
  PencilIcon as Edit,
  TagIcon,
  TrashIcon as Trash,
  XIcon,
} from "@/ui/icons";
import { Button } from "@/ui/button";
import { cn } from "@/utils/cn";
import { useTranslation } from "@/i18n/locale-provider";
import { useGitLogColumnResize } from "../../hooks/use-git-log-column-resize";
import { useGitGraphPaint } from "../../hooks/use-git-graph-paint";
import { useGitGraphReferenceMetrics } from "../../hooks/use-git-graph-reference-metrics";
import { currentGitBranchHashes, shouldHighlightCurrentGitBranch } from "../../utils/git-graph-highlights";
import { groupGitGraphReferences } from "../../utils/git-graph-reference-group";
import {
  type GitLogFilterScope,
  useGitLogPreferencesStore,
} from "../../stores/git-log-preferences.store";
import type { GitCommit, GitReference } from "../../types/git.types";
import { layoutGitGraph } from "../../utils/git-graph-layout";
import { matchesGitLogCommit } from "../../utils/git-log-filter";
import {
  isContiguousGitHistorySelection,
  selectedCommitsInHistoryOrder,
} from "../../utils/git-history-selection";
import { GitGraphRow } from "./git-graph-row";
import { GitLogColumnResizeHandle } from "./git-log-column-resize-handle";
import { GitLogDateCell } from "./git-log-date-cell";
import { isGitHeadCommit } from "../../utils/git-history-message";

export function GitCommitTable({
  commits,
  repositoryCommits,
  references,
  selectedReference,
  emptyState,
  selectedCommit,
  selectedCommitHashes,
  navigationRequest = 0,
  isMutatingHistory,
  hasMore,
  isLoadingMore,
  onSelect,
  onContextSelect,
  onOpenDiff,
  onCompareWithHead,
  onCopyHash,
  onCopyShortHash,
  onCopyMessage,
  onEditMessage,
  onUndo,
  onInteractiveRebase,
  onExportPatch,
  onDelete,
  onSquash,
  onReset,
  onCherryPick,
  onRevert,
  onCreateTag,
  onLoadMore,
}: {
  commits: GitCommit[];
  repositoryCommits?: readonly GitCommit[];
  references?: readonly GitReference[];
  selectedReference?: GitReference | null;
  emptyState?: import("react").ReactNode;
  selectedCommit: GitCommit | null;
  selectedCommitHashes: ReadonlySet<string>;
  /** Explicit reveal, including navigating to an already selected branch head. */
  navigationRequest?: number;
  isMutatingHistory: boolean;
  hasMore: boolean;
  isLoadingMore: boolean;
  onSelect: (
    commit: GitCommit,
    visibleCommitHashes: string[],
    options: { additive: boolean; range: boolean },
  ) => void;
  onContextSelect: (commit: GitCommit) => void;
  onOpenDiff: (commit: GitCommit) => void;
  onCompareWithHead: (commit: GitCommit) => void;
  onCopyHash: (commit: GitCommit) => void;
  onCopyShortHash: (commit: GitCommit) => void;
  onCopyMessage: (commit: GitCommit) => void;
  onEditMessage: (commit: GitCommit) => void;
  onUndo: (commit: GitCommit) => void;
  onInteractiveRebase: (commit: GitCommit) => void;
  onExportPatch: (commits: GitCommit[]) => void;
  onDelete: (commit: GitCommit) => void;
  onSquash: (commits: GitCommit[]) => void;
  onReset: (commit: GitCommit) => void;
  onCherryPick: (commit: GitCommit) => void;
  onRevert: (commit: GitCommit) => void;
  onCreateTag: (commit: GitCommit) => void;
  onLoadMore: () => void;
}) {
  const { t } = useTranslation();
  const query = useGitLogPreferencesStore.use.filterQuery();
  const scope = useGitLogPreferencesStore.use.filterScope();
  const showDecorations = useGitLogPreferencesStore.use.showDecorations();
  const showLongGraphEdges = useGitLogPreferencesStore.use.showLongGraphEdges();
  const { setFilterQuery, setFilterScope, setShowDecorations, setShowLongGraphEdges } =
    useGitLogPreferencesStore.use.actions();
  const scrollRef = useRef<HTMLDivElement>(null);
  const loadMoreRef = useRef<HTMLDivElement>(null);
  const paint = useGitGraphPaint();
  const graphLayout = useMemo(
    () =>
      layoutGitGraph(
        commits,
        query.trim()
          ? new Set(
              commits
                .filter((commit) => matchesGitLogCommit(commit, query, scope))
                .map((commit) => commit.hash),
            )
          : undefined,
        { repositoryCommits, references, displayMode: showLongGraphEdges ? "expanded" : "compact" },
      ),
    [commits, repositoryCommits, references, query, scope, showLongGraphEdges],
  );
  const visibleRows = graphLayout.rows;
  const visibleCommitHashes = useMemo(
    () => visibleRows.map((row) => row.commit.hash),
    [visibleRows],
  );
  const pendingFocusRef = useRef<{
    commit: GitCommit;
    query: string;
    scope: GitLogFilterScope;
    expanded: boolean;
  } | null>(null);
  const focusPendingRow = useCallback(() => {
    const request = pendingFocusRef.current;
    if (!request) return;
    // Reference/context repainting may keep the same commit. Repository or
    // query replacement must never focus a different owner or steal search focus.
    if (
      request.query !== query ||
      request.scope !== scope ||
      request.expanded !== showLongGraphEdges ||
      !visibleRows.some((row) => row.commit === request.commit)
    ) {
      pendingFocusRef.current = null;
      return;
    }
    const target = scrollRef.current?.querySelector<HTMLElement>(
      `[data-git-commit-hash="${request.commit.hash}"]`,
    );
    if (target) {
      pendingFocusRef.current = null;
      target.focus();
    }
  }, [visibleRows, query, scope, showLongGraphEdges]);
  // An offscreen destination may mount after scrollToIndex's first frame.
  // Consume focus on its DOM commit, without timers or frame polling.
  useLayoutEffect(focusPendingRow);
  const virtualizer = useVirtualizer({
    count: visibleRows.length,
    getScrollElement: () => scrollRef.current,
    estimateSize: () => paint.rowHeight,
    overscan: 14,
  });
  const { columnStyle, activeColumn, startResize } = useGitLogColumnResize(scrollRef);
  const referenceMetrics = useGitGraphReferenceMetrics(scrollRef, columnStyle, paint.rowHeight);
  const currentBranchHashes = useMemo(() => shouldHighlightCurrentGitBranch(selectedReference)
    ? currentGitBranchHashes(commits, repositoryCommits ?? [], references ?? []) : new Set<string>(),
    [commits, repositoryCommits, references, selectedReference]);
  const referenceGroups = useMemo(() => new Map(visibleRows.map((row) => [row.commit.hash,
    groupGitGraphReferences(row.labels, references)])), [visibleRows, references]);

  useEffect(() => {
    const element = scrollRef.current;
    if (!element) return;
    const focus = () => { element.dataset.windowActive = "true"; };
    const blur = () => { element.dataset.windowActive = "false"; };
    element.dataset.windowActive = String(document.hasFocus());
    window.addEventListener("focus", focus);
    window.addEventListener("blur", blur);
    return () => { window.removeEventListener("focus", focus); window.removeEventListener("blur", blur); };
  }, []);

  useLayoutEffect(() => {
    virtualizer.measure();
  }, [virtualizer, paint.rowHeight]);

  useEffect(
    () => () => {
      pendingFocusRef.current = null;
    },
    [],
  );

  useLayoutEffect(() => {
    const element = scrollRef.current;
    if (!element) return;
    return bindScrollContainerWheel(element, { smooth: true });
  }, []);

  useEffect(() => {
    const root = scrollRef.current;
    const sentinel = loadMoreRef.current;
    if (!root || !sentinel || !hasMore) return;

    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry?.isIntersecting && !isLoadingMore) onLoadMore();
      },
      {
        root,
        // Start fetching before the user reaches the end so the next page is ready in time.
        rootMargin: "0px 0px 240px 0px",
      },
    );
    observer.observe(sentinel);
    return () => observer.disconnect();
  }, [hasMore, isLoadingMore, onLoadMore]);

  const selectedHash = selectedCommit?.hash ?? null;
  const revealedSelectionRef = useRef<{ hash: string; request: number } | null>(null);
  useEffect(() => {
    if (!selectedHash) {
      revealedSelectionRef.current = null;
      return;
    }
    const previous = revealedSelectionRef.current;
    // Paging and graph repainting are data updates, not navigation requests.
    if (previous?.hash === selectedHash && previous.request === navigationRequest) return;
    const selectedIndex = visibleRows.findIndex((row) => row.commit.hash === selectedHash);
    if (selectedIndex < 0) return;
    revealedSelectionRef.current = { hash: selectedHash, request: navigationRequest };
    virtualizer.scrollToIndex(selectedIndex, { align: "auto" });
  }, [selectedHash, navigationRequest, virtualizer, visibleRows]);

  const selectRowAt = useCallback(
    (index: number, options = { additive: false, range: false }, focusDestination = false) => {
      const nextIndex = Math.max(0, Math.min(index, visibleRows.length - 1));
      const nextCommit = visibleRows[nextIndex]?.commit;
      if (!nextCommit) return;
      pendingFocusRef.current = focusDestination
        ? { commit: nextCommit, query, scope, expanded: showLongGraphEdges } : null;
      // Ordinary keyboard navigation keeps the stable viewport as the menu owner.
      // Explicit graph-arrow navigation transfers focus when its target mounts.
      scrollRef.current?.focus({ preventScroll: true });
      revealedSelectionRef.current = { hash: nextCommit.hash, request: navigationRequest };
      onSelect(nextCommit, visibleCommitHashes, options);
      virtualizer.scrollToIndex(nextIndex, { align: "auto" });
      focusPendingRow();
    },
    [
      onSelect,
      virtualizer,
      visibleCommitHashes,
      visibleRows,
      focusPendingRow,
      query,
      scope,
      showLongGraphEdges,
      navigationRequest,
    ],
  );

  const navigateToHash = useCallback(
    (hash: string) => {
      if (isMutatingHistory) return;
      const index = visibleRows.findIndex((row) => row.commit.hash === hash);
      if (index >= 0) selectRowAt(index, { additive: false, range: false }, true);
    },
    [isMutatingHistory, selectRowAt, visibleRows],
  );

  const handleKeyDown = (event: React.KeyboardEvent) => {
    const target = event.target as HTMLElement;
    // Context-menu portals and embedded controls retain their own keyboard actions.
    if (
      !scrollRef.current?.contains(target) ||
      target.closest("button, input, select, textarea")
    ) return;
    const currentIndex = visibleRows.findIndex((row) => row.commit.hash === selectedCommit?.hash);

    if (event.key === "ContextMenu" || (event.key === "F10" && event.shiftKey)) {
      event.preventDefault();
      event.stopPropagation();
      openSelectedCommitMenu();
      return;
    }

    switch (event.key) {
      case "ArrowDown":
        event.preventDefault();
        selectRowAt(currentIndex + 1, {
          additive: event.ctrlKey || event.metaKey,
          range: event.shiftKey,
        });
        break;
      case "ArrowUp":
        event.preventDefault();
        selectRowAt(Math.max(0, currentIndex - 1), {
          additive: event.ctrlKey || event.metaKey,
          range: event.shiftKey,
        });
        break;
      case "Home":
        event.preventDefault();
        selectRowAt(0);
        break;
      case "End":
        event.preventDefault();
        selectRowAt(visibleRows.length - 1);
        break;
      case "Enter":
        if (currentIndex >= 0) {
          event.preventDefault();
          onOpenDiff(visibleRows[currentIndex]!.commit);
        }
        break;
    }
  };

  const openSelectedCommitMenu = () => {
    const index = visibleRows.findIndex((row) => row.commit.hash === selectedCommit?.hash);
    const trigger = scrollRef.current?.querySelector<HTMLElement>(
      `[data-git-commit-index="${index}"]`,
    );
    if (!trigger) return;
    const bounds = trigger.getBoundingClientRect();
    // Route the keyboard request through the real trigger, preserving Base UI's
    // anchor, selection and menu lifecycle instead of opening the empty-area menu.
    trigger.dispatchEvent(new window.MouseEvent("contextmenu", {
      bubbles: true,
      cancelable: true,
      clientX: bounds.left,
      clientY: bounds.top + bounds.height / 2,
    }));
  };

  return (
    <div className="flex h-full min-h-0 flex-col bg-background font-sans ui-text-sm select-none">
      <div className="flex h-8 shrink-0 items-center gap-2 border-border border-b bg-background px-2">
        <div className="flex h-6 min-w-36 max-w-72 flex-1 items-center gap-1.5 rounded border border-border bg-background px-2 focus-within:border-border-strong">
          <Search className="size-3.5 shrink-0 text-subtle-foreground" />
          <input
            value={query}
            onChange={(event) => setFilterQuery(event.target.value)}
            className="min-w-0 flex-1 bg-transparent outline-none placeholder:text-subtle-foreground"
            placeholder={t("git.log.filterPlaceholder", {
              field: t(
                scope === "author"
                  ? "git.log.filterAuthor"
                  : scope === "branch"
                    ? "git.log.filterBranch"
                    : "git.log.filterText",
              ),
            })}
            aria-label={t("git.log.filter")}
          />
          {query ? (
            <button
              type="button"
              onClick={() => setFilterQuery("")}
              className="text-subtle-foreground hover:text-foreground"
              aria-label={t("git.log.clearFilter")}
            >
              <XIcon className="size-3" />
            </button>
          ) : null}
        </div>
        <select
          value={scope}
          onChange={(event) => setFilterScope(event.target.value as GitLogFilterScope)}
          className="h-6 rounded border border-border bg-background px-1.5 text-subtle-foreground outline-none"
          aria-label={t("git.log.filterField")}
        >
          <option value="text">{t("git.log.filterText")}</option>
          <option value="author">{t("git.log.filterAuthor")}</option>
          <option value="branch">{t("git.log.filterBranch")}</option>
        </select>
        <Button
          type="button"
          variant="ghost"
          size="icon-xs"
          onClick={() => setShowDecorations(!showDecorations)}
          tooltip={showDecorations ? t("git.log.hideDecorations") : t("git.log.showDecorations")}
          aria-label={showDecorations ? t("git.log.hideDecorations") : t("git.log.showDecorations")}
          aria-pressed={showDecorations}
        >
          {showDecorations ? <Eye /> : <EyeSlash />}
        </Button>
        <Button
          type="button"
          variant="ghost"
          size="icon-xs"
          onClick={() => setShowLongGraphEdges(!showLongGraphEdges)}
          tooltip={t(showLongGraphEdges ? "git.log.collapseLongEdges" : "git.log.showLongEdges")}
          aria-label={t(showLongGraphEdges ? "git.log.collapseLongEdges" : "git.log.showLongEdges")}
          aria-pressed={showLongGraphEdges}
        >
          <ArrowsInLineVerticalIcon />
        </Button>
        <span className="shrink-0 text-subtle-foreground tabular-nums">
          {visibleRows.length}/{commits.length}
        </span>
      </div>

      <div
        ref={scrollRef}
        data-scroll-container=""
        tabIndex={0}
        aria-label={t("git.console.log")}
        onKeyDown={handleKeyDown}
        onContextMenu={(event) => {
          if (event.target === event.currentTarget && event.clientX === 0 && event.clientY === 0) {
            event.preventDefault();
            event.stopPropagation();
            openSelectedCommitMenu();
          }
        }}
        onClick={(event) => {
          const target = event.target as HTMLElement;
          if (
            event.currentTarget.contains(target) &&
            !target.closest("button, input, select, textarea")
          ) event.currentTarget.focus({ preventScroll: true });
        }}
        className="git-log-commit-viewport min-h-0 flex-1 overflow-auto outline-none [overflow-anchor:none]"
        style={columnStyle}
      >
        {visibleRows.length === 0 ? (
          commits.length === 0 && emptyState ? (
            emptyState
          ) : (
            <div className="flex h-full items-center justify-center text-subtle-foreground">
              {query ? t("git.log.noMatch") : t("git.log.noCommits")}
            </div>
          )
        ) : (
          <>
            <div
              className="relative"
              style={{
                height: virtualizer.getTotalSize(),
                minWidth: "var(--git-log-row-min-width)",
              }}
            >
              {virtualizer.getVirtualItems().map((virtualRow) => {
                const row = visibleRows[virtualRow.index];
                const isSelected = selectedCommitHashes.has(row.commit.hash);
                const contextSelection = selectedCommitsInHistoryOrder(
                  commits,
                  isSelected ? selectedCommitHashes : new Set([row.commit.hash]),
                );
                const hasMultipleContextCommits = contextSelection.length > 1;
                const canSquash = isContiguousGitHistorySelection(
                  commits,
                  new Set(contextSelection.map((commit) => commit.hash)),
                );
                return (
                  <ContextMenu key={row.commit.hash}>
                    <ContextMenuTrigger
                      role="button"
                      tabIndex={-1}
                      aria-pressed={isSelected}
                      data-git-commit-index={virtualRow.index}
                      data-git-commit-hash={row.commit.hash}
                      data-current-branch={currentBranchHashes.has(row.commit.hash) ? "true" : undefined}
                      data-merge={row.commit.parentHashes.length >= 2 ? "true" : undefined}
                      className={cn(
                        "git-log-commit-row absolute inset-x-0 flex items-center text-left outline-none",
                      )}
                      style={{
                        height: virtualRow.size,
                        transform: `translateY(${virtualRow.start}px)`,
                      }}
                      onClick={(event) => {
                        scrollRef.current?.focus({ preventScroll: true });
                        onSelect(row.commit, visibleCommitHashes, {
                          additive: event.ctrlKey || event.metaKey,
                          range: event.shiftKey,
                        });
                      }}
                      onDoubleClick={() => onOpenDiff(row.commit)}
                      onContextMenu={() => onContextSelect(row.commit)}
                      title={t("git.log.openDiffHint")}
                    >
                      <GitGraphRow
                        row={row}
                        showDecorations={showDecorations}
                        paint={paint}
                        onNavigateHash={navigateToHash}
                        referenceGroup={referenceGroups.get(row.commit.hash)}
                        referenceMetrics={referenceMetrics}
                        recommendedLaneCount={graphLayout.recommendedLaneCount}
                      />
                      <div className="relative flex h-full w-(--git-log-author-width) shrink-0 items-center">
                        <span className="git-log-commit-text min-w-0 flex-1 overflow-clip px-2 text-ellipsis whitespace-nowrap text-foreground">
                          {row.commit.author}
                        </span>
                        <GitLogColumnResizeHandle column="author" onStartResize={startResize} />
                      </div>
                      <div className="relative flex h-full w-(--git-log-date-width) shrink-0 items-center">
                        <GitLogDateCell
                          date={row.commit.date}
                          utcOffsetMinutes={row.commit.dateUtcOffsetMinutes}
                        />
                        <GitLogColumnResizeHandle column="date" onStartResize={startResize} />
                      </div>
                    </ContextMenuTrigger>
                    <ContextMenuContent finalFocus={scrollRef}>
                      {hasMultipleContextCommits ? (
                        <>
                          <ContextMenuItem
                            disabled={isMutatingHistory || !canSquash}
                            title={
                              !canSquash ? t("git.historyReview.contiguousRequired") : undefined
                            }
                            onClick={() => onSquash(contextSelection)}
                          >
                            <Squash />
                            {t("git.squashCommits")}
                          </ContextMenuItem>
                          <ContextMenuItem
                            disabled={isMutatingHistory || contextSelection.length !== 2}
                            title={
                              contextSelection.length !== 2 ? t("git.patch.twoCommits") : undefined
                            }
                            onClick={() => onExportPatch(contextSelection)}
                          >
                            <GitDiff />
                            {t("git.patch.create")}
                          </ContextMenuItem>
                        </>
                      ) : (
                        <>
                          <ContextMenuItem onClick={() => onOpenDiff(row.commit)}>
                            <GitDiff />
                            {t("git.log.openCommitDiff")}
                            <ContextMenuShortcut>Enter</ContextMenuShortcut>
                          </ContextMenuItem>
                          <ContextMenuItem onClick={() => onCompareWithHead(row.commit)}>
                            <GitBranch />
                            {t("git.log.compareWithHead")}
                          </ContextMenuItem>
                          <ContextMenuSeparator />
                          <ContextMenuItem
                            disabled={isMutatingHistory || !isGitHeadCommit(row.commit)}
                            title={
                              !isGitHeadCommit(row.commit)
                                ? t("git.historyReview.headRequired")
                                : undefined
                            }
                            onClick={() => onUndo(row.commit)}
                          >
                            <Reset />
                            {t("git.undoCommit")}
                          </ContextMenuItem>
                          <ContextMenuItem
                            disabled={isMutatingHistory}
                            onClick={() => onInteractiveRebase(row.commit)}
                          >
                            <GitBranch />
                            {t("git.rebasePlan.fromHere")}
                          </ContextMenuItem>
                          <ContextMenuItem
                            disabled={isMutatingHistory}
                            onClick={() => onEditMessage(row.commit)}
                          >
                            <Edit />
                            {t("git.editCommitMessage")}
                          </ContextMenuItem>
                          <ContextMenuItem
                            variant="destructive"
                            disabled={isMutatingHistory}
                            onClick={() => onDelete(row.commit)}
                          >
                            <Trash />
                            {t("git.deleteCommit")}
                          </ContextMenuItem>
                          <ContextMenuItem
                            disabled={isMutatingHistory}
                            onClick={() => onReset(row.commit)}
                          >
                            <Reset />
                            {t("git.resetToCommit")}
                          </ContextMenuItem>
                          <ContextMenuItem
                            disabled={isMutatingHistory || commits[0]?.hash === row.commit.hash}
                            onClick={() => onCherryPick(row.commit)}
                          >
                            <CherryPick />
                            {t("git.cherryPickCommit")}
                          </ContextMenuItem>
                          <ContextMenuItem
                            disabled={isMutatingHistory}
                            onClick={() => onRevert(row.commit)}
                          >
                            <Revert />
                            {t("git.revertCommit")}
                          </ContextMenuItem>
                        </>
                      )}
                      <ContextMenuSeparator />
                      <ContextMenuItem
                        disabled={isMutatingHistory || hasMultipleContextCommits}
                        onClick={() => onCreateTag(row.commit)}
                      >
                        <TagIcon />
                        {t("git.log.newTag")}
                      </ContextMenuItem>
                      {!hasMultipleContextCommits ? (
                        <>
                          <ContextMenuSeparator />
                          <ContextMenuItem onClick={() => onCopyHash(row.commit)}>
                            <Copy />
                            {t("git.log.copyCommitHash")}
                          </ContextMenuItem>
                          <ContextMenuItem onClick={() => onCopyShortHash(row.commit)}>
                            <Copy />
                            {t("git.log.copyShortHash")}
                          </ContextMenuItem>
                          <ContextMenuItem onClick={() => onCopyMessage(row.commit)}>
                            <Copy />
                            {t("git.log.copyCommitMessage")}
                          </ContextMenuItem>
                        </>
                      ) : null}
                    </ContextMenuContent>
                  </ContextMenu>
                );
              })}
            </div>
            {hasMore ? (
              <div
                ref={loadMoreRef}
                className="flex h-9 min-w-130 items-center justify-center border-border border-t"
              >
                <Button
                  type="button"
                  variant="ghost"
                  size="xs"
                  disabled={isLoadingMore}
                  onClick={onLoadMore}
                >
                  {isLoadingMore ? t("git.log.loadingCommits") : t("git.log.loadMore")}
                </Button>
              </div>
            ) : null}
          </>
        )}
      </div>
      {/* Shields the rows from hover and the trailing click while a column is being dragged. */}
      {activeColumn ? <div className="fixed inset-0 z-40 cursor-ew-resize" /> : null}
    </div>
  );
}
