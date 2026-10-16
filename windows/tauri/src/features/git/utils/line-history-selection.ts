export interface LineSpanSelection {
  /** Earlier line of the editor selection, one-based. */
  firstLine: number;
  /** Later line of the editor selection, one-based. */
  lastLine: number;
  /** Column where the later line ends; a value of one parks the caret on the
   * next line without selecting anything there. */
  lastLineColumn: number;
}

export interface LineHistoryRange {
  startLine: number;
  endLine: number;
}

/**
 * Line range a context menu should query: the clicked line alone, unless the
 * click falls inside the selection's line span. A caret parked on the next
 * line's first column never widens the query by that line.
 */
export function gutterLineRange(
  clickedLine: number,
  selection: LineSpanSelection | null,
): LineHistoryRange {
  if (selection && selection.lastLine >= selection.firstLine) {
    const endLine =
      selection.lastLineColumn === 1 && selection.lastLine > selection.firstLine
        ? selection.lastLine - 1
        : selection.lastLine;
    if (
      clickedLine >= selection.firstLine &&
      clickedLine <= endLine &&
      endLine >= selection.firstLine
    ) {
      return { startLine: selection.firstLine, endLine };
    }
  }
  return { startLine: clickedLine, endLine: clickedLine };
}
