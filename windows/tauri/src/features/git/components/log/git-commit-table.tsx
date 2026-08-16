import { useVirtualizer } from "@tanstack/react-virtual";
import { useEffect, useMemo, useRef } from "react";
import {
  ContextMenu,
  ContextMenuContent,
  ContextMenuItem,
  ContextMenuSeparator,
  ContextMenuShortcut,
  ContextMenuTrigger,
} from "@/ui/context-menu";
import {
  CopyIcon as Copy,
  EyeIcon as Eye,
  EyeSlashIcon as EyeSlash,
  GitBranchIcon as GitBranch,
  GitDiffIcon as GitDiff,
  MagnifyingGlassIcon as Search,
  XIcon,
} from "@/ui/icons";
import { Button } from "@/ui/button";
import { cn } from "@/utils/cn";
import {
  type GitLogFilterScope,
  useGitLogPreferencesStore,
} from "../../stores/git-log-preferences.store";
import type { GitCommit } from "../../types/git.types";
import { layoutGitGraph } from "../../utils/git-graph-layout";
import { matchesGitLogCommit } from "../../utils/git-log-filter";
import { GitGraphRow } from "./git-graph-row";

const ROW_HEIGHT = 30;

export function GitCommitTable({
  commits,
  selectedCommit,
  hasMore,
  isLoadingMore,
  onSelect,
  onOpenDiff,
  onCompareWithHead,
  onCopyHash,
  onCopyMessage,
  onLoadMore,
}: {
  commits: GitCommit[];
  selectedCommit: GitCommit | null;
  hasMore: boolean;
  isLoadingMore: boolean;
  onSelect: (commit: GitCommit) => void;
  onOpenDiff: (commit: GitCommit) => void;
  onCompareWithHead: (commit: GitCommit) => void;
  onCopyHash: (commit: GitCommit) => void;
  onCopyMessage: (commit: GitCommit) => void;
  onLoadMore: () => void;
}) {
  const query = useGitLogPreferencesStore.use.filterQuery();
  const scope = useGitLogPreferencesStore.use.filterScope();
  const showDecorations = useGitLogPreferencesStore.use.showDecorations();
  const { setFilterQuery, setFilterScope, setShowDecorations } =
    useGitLogPreferencesStore.use.actions();
  const scrollRef = useRef<HTMLDivElement>(null);
  const layout = useMemo(() => layoutGitGraph(commits), [commits]);
  const visibleRows = useMemo(
    () => layout.rows.filter((row) => matchesGitLogCommit(row.commit, query, scope)),
    [layout.rows, query, scope],
  );
  const virtualizer = useVirtualizer({
    count: visibleRows.length,
    getScrollElement: () => scrollRef.current,
    estimateSize: () => ROW_HEIGHT,
    overscan: 14,
  });

  useEffect(() => {
    if (!selectedCommit) return;
    const selectedIndex = visibleRows.findIndex((row) => row.commit.hash === selectedCommit.hash);
    if (selectedIndex >= 0) virtualizer.scrollToIndex(selectedIndex, { align: "auto" });
  }, [selectedCommit, virtualizer, visibleRows]);

  const selectRowAt = (index: number) => {
    const nextIndex = Math.max(0, Math.min(index, visibleRows.length - 1));
    const nextCommit = visibleRows[nextIndex]?.commit;
    if (!nextCommit) return;
    onSelect(nextCommit);
    virtualizer.scrollToIndex(nextIndex, { align: "auto" });
    globalThis.requestAnimationFrame?.(() => {
      scrollRef.current
        ?.querySelector<HTMLElement>(`[data-git-commit-index="${nextIndex}"]`)
        ?.focus();
    });
  };

  const handleRowKeyDown = (event: React.KeyboardEvent, commit: GitCommit) => {
    const currentIndex = visibleRows.findIndex((row) => row.commit.hash === commit.hash);
    if (currentIndex < 0) return;

    switch (event.key) {
      case "ArrowDown":
        event.preventDefault();
        selectRowAt(currentIndex + 1);
        break;
      case "ArrowUp":
        event.preventDefault();
        selectRowAt(currentIndex - 1);
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
        event.preventDefault();
        onOpenDiff(commit);
        break;
    }
  };

  return (
    <div className="flex h-full min-h-0 flex-col bg-background font-sans ui-text-sm select-none">
      <div className="flex h-8 shrink-0 items-center gap-2 border-border border-b bg-surface px-2">
        <div className="flex h-6 min-w-36 max-w-72 flex-1 items-center gap-1.5 rounded border border-border bg-background px-2 focus-within:border-border-strong">
          <Search className="size-3.5 shrink-0 text-subtle-foreground" />
          <input
            value={query}
            onChange={(event) => setFilterQuery(event.target.value)}
            className="min-w-0 flex-1 bg-transparent outline-none placeholder:text-subtle-foreground"
            placeholder={`${scope[0].toUpperCase()}${scope.slice(1)} filter`}
            aria-label="Filter Git log"
          />
          {query ? (
            <button
              type="button"
              onClick={() => setFilterQuery("")}
              className="text-subtle-foreground hover:text-foreground"
              aria-label="Clear Git log filter"
            >
              <XIcon className="size-3" />
            </button>
          ) : null}
        </div>
        <select
          value={scope}
          onChange={(event) => setFilterScope(event.target.value as GitLogFilterScope)}
          className="h-6 rounded border border-border bg-background px-1.5 text-subtle-foreground outline-none"
          aria-label="Git log filter field"
        >
          <option value="text">Text</option>
          <option value="author">Author</option>
          <option value="branch">Branch</option>
        </select>
        <Button
          type="button"
          variant="ghost"
          size="icon-xs"
          onClick={() => setShowDecorations(!showDecorations)}
          tooltip={showDecorations ? "Hide branch and tag labels" : "Show branch and tag labels"}
          aria-label={showDecorations ? "Hide Git decorations" : "Show Git decorations"}
          aria-pressed={showDecorations}
        >
          {showDecorations ? <Eye /> : <EyeSlash />}
        </Button>
        <span className="shrink-0 text-subtle-foreground tabular-nums">
          {visibleRows.length}/{commits.length}
        </span>
      </div>

      <div className="flex h-6 shrink-0 items-center border-border border-b bg-surface/70 px-2 text-subtle-foreground">
        <span className="min-w-0 flex-1">Commit</span>
        <span className="w-28 shrink-0">Author</span>
        <span className="w-32 shrink-0 text-right">Date</span>
      </div>

      <div ref={scrollRef} className="min-h-0 flex-1 overflow-auto">
        {visibleRows.length === 0 ? (
          <div className="flex h-full items-center justify-center text-subtle-foreground">
            {query ? "No commits match this filter" : "No commits in this view"}
          </div>
        ) : (
          <>
            <div className="relative min-w-130" style={{ height: virtualizer.getTotalSize() }}>
              {virtualizer.getVirtualItems().map((virtualRow) => {
                const row = visibleRows[virtualRow.index];
                const isSelected = selectedCommit?.hash === row.commit.hash;
                return (
                  <ContextMenu key={row.commit.hash}>
                    <ContextMenuTrigger
                      role="button"
                      tabIndex={isSelected || (!selectedCommit && virtualRow.index === 0) ? 0 : -1}
                      aria-current={isSelected ? "true" : undefined}
                      data-git-commit-index={virtualRow.index}
                      className={cn(
                        "absolute inset-x-0 flex items-center border-border/50 border-b px-1 text-left outline-none hover:bg-accent/70 focus-visible:bg-accent/70",
                        isSelected && "bg-primary/22 hover:bg-primary/28",
                      )}
                      style={{
                        height: virtualRow.size,
                        transform: `translateY(${virtualRow.start}px)`,
                      }}
                      onClick={() => onSelect(row.commit)}
                      onDoubleClick={() => onOpenDiff(row.commit)}
                      onContextMenu={() => onSelect(row.commit)}
                      onKeyDown={(event) => handleRowKeyDown(event, row.commit)}
                      title="Double-click or press Enter to open commit diff"
                    >
                      <GitGraphRow row={row} showDecorations={showDecorations} />
                      <span className="w-28 shrink-0 truncate px-2 text-subtle-foreground">
                        {row.commit.author}
                      </span>
                      <span className="w-32 shrink-0 truncate text-right font-mono text-[11px] text-subtle-foreground">
                        {row.commit.date}
                      </span>
                    </ContextMenuTrigger>
                    <ContextMenuContent>
                      <ContextMenuItem onClick={() => onOpenDiff(row.commit)}>
                        <GitDiff />
                        Open Commit Diff
                        <ContextMenuShortcut>Enter</ContextMenuShortcut>
                      </ContextMenuItem>
                      <ContextMenuItem onClick={() => onCompareWithHead(row.commit)}>
                        <GitBranch />
                        Compare with HEAD
                      </ContextMenuItem>
                      <ContextMenuSeparator />
                      <ContextMenuItem onClick={() => onCopyHash(row.commit)}>
                        <Copy />
                        Copy Commit Hash
                      </ContextMenuItem>
                      <ContextMenuItem onClick={() => onCopyMessage(row.commit)}>
                        <Copy />
                        Copy Commit Message
                      </ContextMenuItem>
                    </ContextMenuContent>
                  </ContextMenu>
                );
              })}
            </div>
            {hasMore ? (
              <div className="flex h-9 min-w-130 items-center justify-center border-border border-t">
                <Button
                  type="button"
                  variant="ghost"
                  size="xs"
                  disabled={isLoadingMore}
                  onClick={onLoadMore}
                >
                  {isLoadingMore ? "Loading commits…" : "Load more commits"}
                </Button>
              </div>
            ) : null}
          </>
        )}
      </div>
    </div>
  );
}
