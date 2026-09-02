import { useEditorSettingsStore } from "@/features/editor/stores/settings.store";
import { useSelectionScope } from "@/features/editor/hooks/use-selection-scope";
import { calculateLineHeight } from "@/features/editor/utils/lines";
import { memo, useCallback, useMemo, useRef, useState } from "react";
import { useZoomStore } from "@/features/window/stores/zoom.store";
import { Empty, EmptyDescription } from "@/ui/empty";
import { useTranslation } from "@/i18n/locale-provider";
import { useDiffHighlighting } from "../../hooks/use-git-diff-highlight";
import type {
  DiffSearchHighlight,
  ParsedHunk,
  TextDiffViewerProps,
} from "../../types/git-diff.types";
import type { GitDiffSplitRow } from "../../types/git.types";
import { DIFF_HIGHLIGHT_LINE_THRESHOLD } from "../../utils/diff-viewer-scale";
import {
  createFallbackSplitRows,
  countSplitDiffStats,
  getSkippedUnchangedLineCount,
  groupLinesIntoHunks,
  hasInvisibleDiffChanges,
} from "../../utils/git-diff-helpers";
import {
  planSplitDiffLayout,
  resolveDiffViewMode,
  type SplitDiffLayoutItem,
} from "../../utils/git-diff-split-layout";
import GitDiffConnectorOverlay, {
  GIT_DIFF_CONNECTOR_GUTTER_WIDTH,
} from "./git-diff-connector-overlay";
import DiffHunkHeader from "./git-diff-hunk-header";
import DiffLine, {
  getContentColor,
  getGutterBackground,
  getGutterTextColor,
  getLineBackground,
  getRailClassName,
  renderDiffLineContent,
} from "./git-diff-line";

const SPLIT_DIFF_LINE_NUMBER_GUTTER_WIDTH = 44;

function SplitDiffCodePanel({
  panelKey,
  side,
  rows,
  items,
  sourceLines,
  tokenMap,
  showWhitespace,
  fontSize,
  lineHeight,
  rowHeight,
  tabSize,
  contentHeight,
  contentWidthCh,
  registerScrollNode,
  onHorizontalScroll,
  searchHighlights,
}: {
  panelKey: string;
  side: "left" | "right";
  rows: GitDiffSplitRow[];
  items: SplitDiffLayoutItem[];
  sourceLines: ParsedHunk["lines"];
  tokenMap: ReturnType<typeof useDiffHighlighting>;
  showWhitespace: boolean;
  fontSize: number;
  lineHeight: number;
  rowHeight: number;
  tabSize: number;
  contentHeight: number;
  contentWidthCh: number;
  registerScrollNode: (key: string, node: HTMLDivElement | null) => void;
  onHorizontalScroll: (source: HTMLDivElement) => void;
  searchHighlights?: Map<number, DiffSearchHighlight[]>;
}) {
  const sourceLinesByNumber = useMemo(() => {
    const entries = sourceLines.flatMap((line) => {
      const lineNumber = side === "left" ? line.old_line_number : line.new_line_number;
      const visible = side === "left" ? line.line_type !== "added" : line.line_type !== "removed";
      return visible && lineNumber !== undefined ? [[lineNumber, line] as const] : [];
    });
    return new Map(entries);
  }, [side, sourceLines]);

  const contentStyle = {
    fontSize: `${fontSize}px`,
    lineHeight: `${lineHeight}px`,
    tabSize,
    whiteSpace: "pre" as const,
    overflowWrap: "normal" as const,
    wordBreak: "normal" as const,
  };

  return (
    <div className="flex min-w-0 flex-1" style={{ height: `${contentHeight * rowHeight}px` }}>
      <div
        className="relative shrink-0 border-border border-r bg-background"
        style={{
          width: `${SPLIT_DIFF_LINE_NUMBER_GUTTER_WIDTH}px`,
          height: `${contentHeight * rowHeight}px`,
        }}
      >
        {items.map((item) => {
          const row = rows[item.rowIndex];
          const lineNumber = side === "left" ? row.old_line_number : row.new_line_number;
          const content = side === "left" ? row.old_content : row.new_content;
          const isVisible = content !== undefined;
          const diffType = isVisible
            ? side === "left" && (row.kind === "changed" || row.kind === "removal")
              ? "removed"
              : side === "right" && (row.kind === "changed" || row.kind === "addition")
                ? "added"
                : "context"
            : "context";
          return (
            <div
              key={`${side}-gutter-${item.rowIndex}`}
              className={`absolute inset-x-0 select-none px-2 py-0.5 text-right tabular-nums ${getGutterBackground(diffType)} ${getRailClassName(diffType)} ${getGutterTextColor(diffType)}`}
              style={{
                fontSize: `${fontSize}px`,
                lineHeight: `${lineHeight}px`,
                top: `${item.top * rowHeight}px`,
                height: `${item.height * rowHeight}px`,
              }}
              data-selection-scope-exclude="true"
            >
              {isVisible ? lineNumber : ""}
            </div>
          );
        })}
      </div>

      <div
        ref={(node) => registerScrollNode(panelKey, node)}
        className="scrollbar-none min-w-0 flex-1 overflow-x-auto overflow-y-hidden"
        onScroll={(event) => onHorizontalScroll(event.currentTarget)}
      >
        <div
          className="relative min-w-full"
          style={{
            width: `${contentWidthCh}ch`,
            height: `${contentHeight * rowHeight}px`,
          }}
        >
          {items.map((item) => {
            const row = rows[item.rowIndex];
            const lineNumber = side === "left" ? row.old_line_number : row.new_line_number;
            const content = side === "left" ? row.old_content : row.new_content;
            const sourceLine = lineNumber === undefined ? undefined : sourceLinesByNumber.get(lineNumber);
            const isVisible = content !== undefined;
            const diffType = isVisible
              ? side === "left" && (row.kind === "changed" || row.kind === "removal")
                ? "removed"
                : side === "right" && (row.kind === "changed" || row.kind === "addition")
                  ? "added"
                  : "context"
              : "context";
            const tokens = sourceLine ? tokenMap.get(sourceLine.diffIndex) : undefined;
            return (
              <div
                key={`${side}-code-${item.rowIndex}`}
                className={`absolute right-0 left-0 px-2.5 py-0.5 ${getLineBackground(diffType)}`}
                style={{
                  ...contentStyle,
                  top: `${item.top * rowHeight}px`,
                  height: `${item.height * rowHeight}px`,
                }}
                data-diff-search-line={sourceLine?.diffIndex}
              >
                <span className={isVisible ? getContentColor(diffType) : undefined}>
                  {isVisible
                    ? renderDiffLineContent(
                        content,
                        tokens,
                        showWhitespace,
                        sourceLine ? searchHighlights?.get(sourceLine.diffIndex) : undefined,
                      )
                    : ""}
                </span>
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}

const TextDiffViewer = memo(
  ({
    diff,
    isStaged,
    viewMode,
    showWhitespace,
    onStageHunk,
    onUnstageHunk,
    isInMultiFileView = false,
    isEmbeddedInScrollView = false,
    searchHighlights,
  }: TextDiffViewerProps) => {
    const { t } = useTranslation();
    const selectionScopeRef = useRef<HTMLDivElement>(null);
    const editorFontSize = useEditorSettingsStore.use.fontSize();
    const editorFontFamily = useEditorSettingsStore.use.fontFamily();
    const editorLineHeight = useEditorSettingsStore.use.lineHeight();
    const editorTabSize = useEditorSettingsStore.use.tabSize();
    const wordWrap = useEditorSettingsStore.use.wordWrap();
    const zoomLevel = useZoomStore.use.editorZoomLevel();
    const fontSize = editorFontSize * zoomLevel;
    const lineHeight = calculateLineHeight(fontSize, editorLineHeight);
    const splitRowHeight = lineHeight + 4;
    const tabSize = editorTabSize;
    const displayViewMode = resolveDiffViewMode(diff, viewMode);

    const hunks = useMemo(() => groupLinesIntoHunks(diff.lines), [diff.lines]);
    const splitHunkRows = useMemo(
      () =>
        hunks.map(
          (hunk, hunkIndex) =>
            diff.split_hunks?.[hunkIndex] ?? createFallbackSplitRows(hunk.lines),
        ),
      [diff.split_hunks, hunks],
    );
    const splitContentWidthCh = useMemo(() => {
      let longestLine = 0;
      for (const rows of splitHunkRows) {
        for (const row of rows) {
          longestLine = Math.max(
            longestLine,
            row.old_content?.length ?? 0,
            row.new_content?.length ?? 0,
          );
        }
      }
      return Math.max(24, longestLine + 6);
    }, [splitHunkRows]);
    const syntaxPath = diff.new_path || diff.old_path || diff.file_path;
    const highlightLines = diff.lines.length <= DIFF_HIGHLIGHT_LINE_THRESHOLD ? diff.lines : [];
    const tokenMap = useDiffHighlighting(highlightLines, syntaxPath);

    const [collapsedHunks, setCollapsedHunks] = useState<Set<number>>(new Set());
    const splitScrollNodesRef = useRef(new Map<string, HTMLDivElement>());
    const sharedHorizontalScrollRef = useRef<HTMLDivElement>(null);
    useSelectionScope(selectionScopeRef);

    const registerSplitScrollNode = useCallback((key: string, node: HTMLDivElement | null) => {
      if (node) {
        splitScrollNodesRef.current.set(key, node);
      } else {
        splitScrollNodesRef.current.delete(key);
      }
    }, []);

    const syncHorizontalScroll = useCallback((source: HTMLDivElement) => {
      const targetScrollLeft = source.scrollLeft;
      for (const node of splitScrollNodesRef.current.values()) {
        if (node !== source && Math.abs(node.scrollLeft - targetScrollLeft) > 0.5) {
          node.scrollLeft = targetScrollLeft;
        }
      }

      const sharedScroller = sharedHorizontalScrollRef.current;
      if (
        sharedScroller &&
        sharedScroller !== source &&
        Math.abs(sharedScroller.scrollLeft - targetScrollLeft) > 0.5
      ) {
        sharedScroller.scrollLeft = targetScrollLeft;
      }
    }, []);

    const toggleHunkCollapse = useCallback((hunkId: number) => {
      setCollapsedHunks((prev) => {
        const newSet = new Set(prev);
        if (newSet.has(hunkId)) {
          newSet.delete(hunkId);
        } else {
          newSet.add(hunkId);
        }
        return newSet;
      });
    }, []);

    if (diff.lines.length === 0) {
      return (
        <Empty className="min-h-0 flex-none rounded-none py-8">
          <EmptyDescription>{t("git.noChangesInFile")}</EmptyDescription>
        </Empty>
      );
    }

    if (displayViewMode === "split" && !wordWrap) {
      return (
        <div
          ref={selectionScopeRef}
          className="font-mono code-editor-font-override min-w-0"
          data-diff-outer-wheel={isEmbeddedInScrollView ? "" : undefined}
          style={{
            fontSize: `${fontSize}px`,
            fontFamily: editorFontFamily,
            lineHeight: `${lineHeight}px`,
            tabSize,
          }}
        >
          {hunks.map((hunk, hunkIndex) => {
            const isCollapsed = collapsedHunks.has(hunk.id);
            const hiddenLineCount = getSkippedUnchangedLineCount(hunks[hunkIndex - 1], hunk);
            const splitRows = splitHunkRows[hunkIndex] ?? [];
            const splitLayout = planSplitDiffLayout(splitRows);
            return (
              <div key={`split-${hunk.id}`}>
                <DiffHunkHeader
                  hunk={hunk}
                  stats={countSplitDiffStats([splitRows])}
                  hasInvisibleChanges={hasInvisibleDiffChanges(splitRows)}
                  hiddenLineCount={hiddenLineCount}
                  isCollapsed={isCollapsed}
                  onToggleCollapse={() => toggleHunkCollapse(hunk.id)}
                  isStaged={isStaged}
                  filePath={diff.file_path}
                  onStageHunk={onStageHunk}
                  onUnstageHunk={onUnstageHunk}
                  isInMultiFileView={isInMultiFileView}
                />
                {!isCollapsed && (
                  <div
                    className="relative grid min-w-0 overflow-hidden"
                    style={{
                      gridTemplateColumns: `minmax(0, 1fr) ${GIT_DIFF_CONNECTOR_GUTTER_WIDTH}px minmax(0, 1fr)`,
                      height: `${splitLayout.contentHeight * splitRowHeight}px`,
                    }}
                  >
                    <div className="min-w-0 overflow-hidden">
                      <SplitDiffCodePanel
                        panelKey={`${hunk.id}-left`}
                        side="left"
                        rows={splitRows}
                        items={splitLayout.leftItems}
                        sourceLines={hunk.lines}
                        tokenMap={tokenMap}
                        showWhitespace={showWhitespace}
                        fontSize={fontSize}
                        lineHeight={lineHeight}
                        rowHeight={splitRowHeight}
                        tabSize={tabSize}
                        contentHeight={splitLayout.contentHeight}
                        contentWidthCh={splitContentWidthCh}
                        registerScrollNode={registerSplitScrollNode}
                        onHorizontalScroll={syncHorizontalScroll}
                        searchHighlights={searchHighlights}
                      />
                    </div>
                    <div className="border-border border-x bg-background" />
                    <div className="min-w-0 overflow-hidden">
                      <SplitDiffCodePanel
                        panelKey={`${hunk.id}-right`}
                        side="right"
                        rows={splitRows}
                        items={splitLayout.rightItems}
                        sourceLines={hunk.lines}
                        tokenMap={tokenMap}
                        showWhitespace={showWhitespace}
                        fontSize={fontSize}
                        lineHeight={lineHeight}
                        rowHeight={splitRowHeight}
                        tabSize={tabSize}
                        contentHeight={splitLayout.contentHeight}
                        contentWidthCh={splitContentWidthCh}
                        registerScrollNode={registerSplitScrollNode}
                        onHorizontalScroll={syncHorizontalScroll}
                        searchHighlights={searchHighlights}
                      />
                    </div>
                    <GitDiffConnectorOverlay
                      transitions={splitLayout.transitions}
                      rowHeight={splitRowHeight}
                    />
                  </div>
                )}
              </div>
            );
          })}
          <div
            ref={sharedHorizontalScrollRef}
            className="sticky bottom-0 z-20 h-3 overflow-x-auto overflow-y-hidden border-border/70 border-t bg-background"
            onScroll={(event) => syncHorizontalScroll(event.currentTarget)}
            aria-label={t("git.diff.synchronizedHorizontalScroll")}
          >
            <div
              className="h-px"
              style={{
                width: `calc(${splitContentWidthCh}ch + 50% + ${SPLIT_DIFF_LINE_NUMBER_GUTTER_WIDTH + GIT_DIFF_CONNECTOR_GUTTER_WIDTH / 2}px)`,
              }}
            />
          </div>
        </div>
      );
    }

    return (
      <div
        ref={selectionScopeRef}
        data-diff-outer-wheel={isEmbeddedInScrollView ? "" : undefined}
        className={
          isEmbeddedInScrollView
            ? "min-w-0 overflow-x-auto overflow-y-hidden"
            : displayViewMode === "split"
              ? "min-w-0 overflow-hidden"
              : "min-w-0 overflow-x-auto overflow-y-hidden"
        }
      >
        <div
          className={
            displayViewMode === "split"
              ? "font-mono code-editor-font-override min-w-0 w-full"
              : "font-mono code-editor-font-override min-w-full w-fit"
          }
          style={{
            fontSize: `${fontSize}px`,
            fontFamily: editorFontFamily,
            lineHeight: `${lineHeight}px`,
            tabSize,
          }}
        >
          {hunks.map((hunk, hunkIndex) => {
            const isCollapsed = collapsedHunks.has(hunk.id);
            const hiddenLineCount = getSkippedUnchangedLineCount(hunks[hunkIndex - 1], hunk);
            const splitRows = splitHunkRows[hunkIndex] ?? [];
            return (
              <div key={hunk.id}>
                <DiffHunkHeader
                  hunk={hunk}
                  stats={countSplitDiffStats([splitRows])}
                  hasInvisibleChanges={hasInvisibleDiffChanges(splitRows)}
                  hiddenLineCount={hiddenLineCount}
                  isCollapsed={isCollapsed}
                  onToggleCollapse={() => toggleHunkCollapse(hunk.id)}
                  isStaged={isStaged}
                  filePath={diff.file_path}
                  onStageHunk={onStageHunk}
                  onUnstageHunk={onUnstageHunk}
                  isInMultiFileView={isInMultiFileView}
                />
                {!isCollapsed &&
                  hunk.lines.map((line, lineIndex) => (
                    <DiffLine
                      key={`${hunk.id}-${lineIndex}`}
                      line={line}
                      viewMode={displayViewMode}
                      wordWrap={wordWrap}
                      showWhitespace={showWhitespace}
                      fontSize={fontSize}
                      lineHeight={lineHeight}
                      tabSize={tabSize}
                      tokens={tokenMap.get(line.diffIndex)}
                      searchHighlights={searchHighlights?.get(line.diffIndex)}
                      searchLineIndex={line.diffIndex}
                    />
                  ))}
              </div>
            );
          })}
        </div>
      </div>
    );
  },
);

TextDiffViewer.displayName = "TextDiffViewer";

export default TextDiffViewer;
