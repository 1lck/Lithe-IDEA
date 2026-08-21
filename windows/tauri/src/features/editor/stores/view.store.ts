import isEqual from "fast-deep-equal";
import { createWithEqualityFn } from "zustand/traditional";
import { isEditorContent } from "@/features/panes/types/pane-content.types";
import { createSelectors } from "@/utils/zustand-selectors";
import type { EditorTextChange } from "../types/editor.types";
import { createSparseLineArray, applyEditorTextChangeToLargeEditorModeInfo, applyIncrementalLargeEditorModeInfo, getLargeEditorModeInfo, type LargeEditorModeInfo } from "../utils/large-file";
import { sortEditorTextChangesForOriginalDocument } from "../utils/editor-text-change";
import { useBufferStore } from "./buffer.store";

interface EditorViewState {
  // Computed views of the active buffer
  lines: string[];
  lineCount: number;
  tooLargeForEditorServices: boolean;

  // Actions
  actions: {
    getLines: () => string[];
    getLineCount: () => number;
    getContent: () => string;
  };
}

export const useEditorViewStore = createSelectors(
  createWithEqualityFn<EditorViewState>()(
    (_set, get) => ({
      // These will be computed from the active buffer
      lines: [""],
      lineCount: 1,
      tooLargeForEditorServices: false,

      actions: {
        getLines: () => {
          const { lines, lineCount } = get();
          if (lines.length > 0) return lines;
          return createSparseLineArray(lineCount);
        },

        getLineCount: () => get().lineCount,

        getContent: () => {
          const activeBuffer = useBufferStore.getState().actions.getActiveBuffer();
          if (!activeBuffer || !isEditorContent(activeBuffer)) return "";
          return activeBuffer.content;
        },
      },
    }),
    isEqual,
  ),
);

let previousActiveBufferSnapshot: {
  id: string;
  content: string;
  lines: string[];
  largeEditorInfo: LargeEditorModeInfo;
} | null = null;

const INCREMENTAL_LINE_EDIT_THRESHOLD = 1000;

function isSparseLineArray(lines: string[]): boolean {
  return lines.length > 0 && Object.keys(lines).length === 0;
}

function findCommonPrefixLength(a: string, b: string): number {
  const minLength = Math.min(a.length, b.length);
  let index = 0;
  while (index < minLength && a[index] === b[index]) {
    index++;
  }
  return index;
}

function findCommonSuffixLength(a: string, b: string, prefixLength: number): number {
  const maxSuffixLength = Math.min(a.length - prefixLength, b.length - prefixLength);
  let suffixLength = 0;

  while (
    suffixLength < maxSuffixLength &&
    a[a.length - 1 - suffixLength] === b[b.length - 1 - suffixLength]
  ) {
    suffixLength++;
  }

  return suffixLength;
}

function getLinePositionForOffset(lines: string[], offset: number) {
  let currentOffset = 0;

  for (let line = 0; line < lines.length; line++) {
    const lineLength = lines[line].length;
    const lineEnd = currentOffset + lineLength;

    if (offset <= lineEnd) {
      return { line, column: offset - currentOffset };
    }

    currentOffset = lineEnd + 1;
  }

  const lastLine = Math.max(0, lines.length - 1);
  return { line: lastLine, column: lines[lastLine]?.length ?? 0 };
}

export function applyIncrementalLineEdit(
  previousContent: string,
  nextContent: string,
  previousLines: string[],
): string[] | null {
  if (isSparseLineArray(previousLines)) {
    return null;
  }

  if (previousContent === nextContent) {
    return previousLines;
  }

  const prefixLength = findCommonPrefixLength(previousContent, nextContent);
  const suffixLength = findCommonSuffixLength(previousContent, nextContent, prefixLength);
  const previousEndOffset = previousContent.length - suffixLength;
  const nextEndOffset = nextContent.length - suffixLength;
  const removedLength = previousEndOffset - prefixLength;
  const insertedLength = nextEndOffset - prefixLength;

  if (
    removedLength < 0 ||
    insertedLength < 0 ||
    Math.max(removedLength, insertedLength) > INCREMENTAL_LINE_EDIT_THRESHOLD
  ) {
    return null;
  }

  const start = getLinePositionForOffset(previousLines, prefixLength);
  const end = getLinePositionForOffset(previousLines, previousEndOffset);
  const insertedText = nextContent.slice(prefixLength, nextEndOffset);
  const insertedLines = insertedText.split("\n");
  const linePrefix = previousLines[start.line]?.slice(0, start.column) ?? "";
  const lineSuffix = previousLines[end.line]?.slice(end.column) ?? "";
  const replacement =
    insertedLines.length === 1
      ? [`${linePrefix}${insertedLines[0]}${lineSuffix}`]
      : [
          `${linePrefix}${insertedLines[0]}`,
          ...insertedLines.slice(1, -1),
          `${insertedLines[insertedLines.length - 1]}${lineSuffix}`,
        ];

  previousLines.splice(start.line, end.line - start.line + 1, ...replacement);
  return previousLines;
}

export function applyEditorTextChangeToLines(
  previousLines: string[],
  change: EditorTextChange,
): string[] | null {
  if (isSparseLineArray(previousLines)) return null;

  const { startLine, startColumn, endLine, endColumn } = change;
  if (
    startLine === undefined ||
    startColumn === undefined ||
    endLine === undefined ||
    endColumn === undefined ||
    startLine < 0 ||
    endLine < startLine ||
    endLine >= previousLines.length ||
    Math.max(change.rangeLength, change.text.length) > INCREMENTAL_LINE_EDIT_THRESHOLD
  ) {
    return null;
  }

  const startLineText = previousLines[startLine] ?? "";
  const endLineText = previousLines[endLine] ?? "";
  if (
    startColumn < 0 ||
    startColumn > startLineText.length ||
    endColumn < 0 ||
    endColumn > endLineText.length
  ) {
    return null;
  }

  const insertedLines = change.text.split("\n");
  const linePrefix = startLineText.slice(0, startColumn);
  const lineSuffix = endLineText.slice(endColumn);
  const replacement =
    insertedLines.length === 1
      ? [`${linePrefix}${insertedLines[0]}${lineSuffix}`]
      : [
          `${linePrefix}${insertedLines[0]}`,
          ...insertedLines.slice(1, -1),
          `${insertedLines[insertedLines.length - 1]}${lineSuffix}`,
        ];

  previousLines.splice(startLine, endLine - startLine + 1, ...replacement);
  return previousLines;
}

interface PendingEditorViewContentChange {
  previousContent: string;
  nextContent: string;
  changes: EditorTextChange[];
}

const pendingEditorViewContentChanges = new Map<string, PendingEditorViewContentChange>();

export function queueEditorViewContentChange(
  bufferId: string,
  previousContent: string,
  nextContent: string,
  change: EditorTextChange | EditorTextChange[],
): void {
  const changes = Array.isArray(change) ? change : [change];
  pendingEditorViewContentChanges.set(bufferId, {
    previousContent,
    nextContent,
    changes,
  });
}

// Subscribe to buffer changes and update computed values
useBufferStore.subscribe((state) => {
  const activeBuffer = state.actions.getActiveBuffer();
  if (activeBuffer && isEditorContent(activeBuffer)) {
    const bufferContent = typeof activeBuffer.content === "string" ? activeBuffer.content : "";
    const previousSnapshot = previousActiveBufferSnapshot;

    if (
      previousSnapshot &&
      previousSnapshot.id === activeBuffer.id &&
      previousSnapshot.content === bufferContent
    ) {
      return;
    }

    const pendingContentChange = pendingEditorViewContentChanges.get(activeBuffer.id);
    pendingEditorViewContentChanges.delete(activeBuffer.id);
    const canApplyQueuedChange =
      previousSnapshot?.id === activeBuffer.id &&
      pendingContentChange?.previousContent === previousSnapshot.content &&
      pendingContentChange.nextContent === bufferContent;

    let largeEditorInfo: LargeEditorModeInfo | null = null;
    if (canApplyQueuedChange && previousSnapshot && pendingContentChange) {
      largeEditorInfo = previousSnapshot.largeEditorInfo;
      for (const change of sortEditorTextChangesForOriginalDocument(pendingContentChange.changes)) {
        const nextInfo = applyEditorTextChangeToLargeEditorModeInfo(
          largeEditorInfo,
          change,
          bufferContent.length,
        );
        if (!nextInfo) {
          largeEditorInfo = null;
          break;
        }
        largeEditorInfo = nextInfo;
      }
    }
    if (!largeEditorInfo && previousSnapshot?.id === activeBuffer.id) {
      largeEditorInfo = applyIncrementalLargeEditorModeInfo(
        previousSnapshot.content,
        bufferContent,
        previousSnapshot.largeEditorInfo,
      );
    }
    largeEditorInfo ??= getLargeEditorModeInfo(bufferContent);

    if (largeEditorInfo.largeContentMode) {
      const lines: string[] = [];
      previousActiveBufferSnapshot = {
        id: activeBuffer.id,
        content: bufferContent,
        lines,
        largeEditorInfo,
      };
      useEditorViewStore.setState({
        lines,
        lineCount: largeEditorInfo.lineCount,
        tooLargeForEditorServices: true,
      });
      return;
    }

    const previousLines =
      previousSnapshot?.id === activeBuffer.id ? previousSnapshot.lines.slice() : [""];
    let changedLines: string[] | null = null;
    if (canApplyQueuedChange && pendingContentChange) {
      changedLines = previousLines;
      for (const change of sortEditorTextChangesForOriginalDocument(pendingContentChange.changes)) {
        const nextLines = applyEditorTextChangeToLines(changedLines, change);
        if (!nextLines) {
          changedLines = null;
          break;
        }
        changedLines = nextLines;
      }
    }
    const lines =
      previousSnapshot?.id === activeBuffer.id
        ? (changedLines ??
          applyIncrementalLineEdit(
            previousSnapshot.content,
            bufferContent,
            previousSnapshot.lines.slice(),
          ) ??
          bufferContent.split("\n"))
        : bufferContent.split("\n");

    previousActiveBufferSnapshot = {
      id: activeBuffer.id,
      content: bufferContent,
      lines,
      largeEditorInfo,
    };

    useEditorViewStore.setState({
      lines,
      lineCount: lines.length,
      tooLargeForEditorServices: largeEditorInfo.largeContentMode,
    });
  } else {
    previousActiveBufferSnapshot = null;
    useEditorViewStore.setState({
      lines: [""],
      lineCount: 1,
      tooLargeForEditorServices: false,
    });
  }
});
