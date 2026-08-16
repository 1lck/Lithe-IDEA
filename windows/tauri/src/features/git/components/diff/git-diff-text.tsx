import { useEditorSettingsStore } from "@/features/editor/stores/settings.store";
import { useSelectionScope } from "@/features/editor/hooks/use-selection-scope";
import { calculateLineHeight } from "@/features/editor/utils/lines";
import { memo, useCallback, useMemo, useRef, useState } from "react";
import { useZoomStore } from "@/features/window/stores/zoom.store";
import { Empty, EmptyDescription } from "@/ui/empty";
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
} from "../../utils/git-diff-helpers";
import DiffHunkHeader from "./git-diff-hunk-header";
import DiffLine, {
  getContentColor,
  getGutterBackground,
  getGutterTextColor,
  getLineBackground,
  getRailClassName,
  renderDiffLineContent,
} from "./git-diff-line";

function SplitDiffCodePanel({
  side,
  rows,
  sourceLines,
  tokenMap,
  showWhitespace,
  fontSize,
  lineHeight,
  tabSize,
  searchHighlights,
}: {
  side: "left" | "right";
  rows: GitDiffSplitRow[];
  sourceLines: ParsedHunk["lines"];
  tokenMap: ReturnType<typeof useDiffHighlighting>;
  showWhitespace: boolean;
  fontSize: number;
  lineHeight: number;
  tabSize: number;
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
    <div className="flex min-w-0 flex-1">
      <div className="w-11 shrink-0 border-border border-r bg-background">
        {rows.map((row, index) => {
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
              key={`${side}-gutter-${index}`}
              className={`select-none px-2 py-0.5 text-right tabular-nums ${getGutterBackground(diffType)} ${getRailClassName(diffType)} ${getGutterTextColor(diffType)}`}
              style={{
                fontSize: `${fontSize}px`,
                lineHeight: `${lineHeight}px`,
              }}
              data-selection-scope-exclude="true"
            >
              {isVisible ? lineNumber : ""}
            </div>
          );
        })}
      </div>

      <div className="min-w-0 flex-1 overflow-x-auto overflow-y-hidden">
        <div className="min-w-max">
          {rows.map((row, index) => {
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
                key={`${side}-code-${index}`}
                className={`px-2.5 py-0.5 ${getLineBackground(diffType)}`}
                style={contentStyle}
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
    const selectionScopeRef = useRef<HTMLDivElement>(null);
    const editorFontSize = useEditorSettingsStore.use.fontSize();
    const editorFontFamily = useEditorSettingsStore.use.fontFamily();
    const editorLineHeight = useEditorSettingsStore.use.lineHeight();
    const editorTabSize = useEditorSettingsStore.use.tabSize();
    const wordWrap = useEditorSettingsStore.use.wordWrap();
    const zoomLevel = useZoomStore.use.editorZoomLevel();
    const fontSize = editorFontSize * zoomLevel;
    const lineHeight = calculateLineHeight(fontSize, editorLineHeight);
    const tabSize = editorTabSize;

    const hunks = useMemo(() => groupLinesIntoHunks(diff.lines), [diff.lines]);
    const syntaxPath = diff.new_path || diff.old_path || diff.file_path;
    const highlightLines = diff.lines.length <= DIFF_HIGHLIGHT_LINE_THRESHOLD ? diff.lines : [];
    const tokenMap = useDiffHighlighting(highlightLines, syntaxPath);

    const [collapsedHunks, setCollapsedHunks] = useState<Set<number>>(new Set());
    useSelectionScope(selectionScopeRef);

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
          <EmptyDescription>No changes in this file</EmptyDescription>
        </Empty>
      );
    }

    if (viewMode === "split" && !wordWrap) {
      return (
        <div
          ref={selectionScopeRef}
          className="font-mono code-editor-font-override min-w-0"
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
            const splitRows = diff.split_hunks?.[hunkIndex] ?? createFallbackSplitRows(hunk.lines);
            return (
              <div key={`split-${hunk.id}`}>
                <DiffHunkHeader
                  hunk={hunk}
                  stats={countSplitDiffStats([splitRows])}
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
                  <div className="flex min-w-0">
                    <div className="min-w-0 flex-1 border-border border-r">
                      <SplitDiffCodePanel
                        side="left"
                        rows={splitRows}
                        sourceLines={hunk.lines}
                        tokenMap={tokenMap}
                        showWhitespace={showWhitespace}
                        fontSize={fontSize}
                        lineHeight={lineHeight}
                        tabSize={tabSize}
                        searchHighlights={searchHighlights}
                      />
                    </div>
                    <div className="min-w-0 flex-1">
                      <SplitDiffCodePanel
                        side="right"
                        rows={splitRows}
                        sourceLines={hunk.lines}
                        tokenMap={tokenMap}
                        showWhitespace={showWhitespace}
                        fontSize={fontSize}
                        lineHeight={lineHeight}
                        tabSize={tabSize}
                        searchHighlights={searchHighlights}
                      />
                    </div>
                  </div>
                )}
              </div>
            );
          })}
        </div>
      );
    }

    return (
      <div
        ref={selectionScopeRef}
        className={
          isEmbeddedInScrollView
            ? "min-w-0 overflow-x-auto overflow-y-hidden"
            : viewMode === "split"
              ? "min-w-0 overflow-hidden"
              : "min-w-0 overflow-x-auto overflow-y-hidden"
        }
      >
        <div
          className={
            viewMode === "split"
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
            const splitRows = diff.split_hunks?.[hunkIndex] ?? createFallbackSplitRows(hunk.lines);
            return (
              <div key={hunk.id}>
                <DiffHunkHeader
                  hunk={hunk}
                  stats={countSplitDiffStats([splitRows])}
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
                      viewMode={viewMode}
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
