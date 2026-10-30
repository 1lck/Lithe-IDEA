import type { GitBlame } from "../types/git.types";

/** One line's annotation as it appears inside the line-number gutter. */
export interface GitBlameGutterEntry {
  commitHash: string;
  /** Author and date as shown left of the line number. */
  text: string;
  /** Hover text carrying the short hash; the label again while uncommitted. */
  title: string;
  isUncommitted: boolean;
}

/** Escapes text that reaches the gutter as HTML. Author names are user data. */
export function escapeGitBlameHtml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/**
 * Formats the authoring date the way IDEA and the macOS workbench annotate a
 * line: `yyyy/M/d`, an absolute date with unpadded month and day instead of a
 * relative one, so a stale annotation cannot read as "3 days ago" forever.
 */
export function formatGitBlameDate(unixSeconds: number): string {
  if (!Number.isFinite(unixSeconds) || unixSeconds <= 0) return "";
  const date = new Date(unixSeconds * 1000);
  return `${date.getFullYear()}/${date.getMonth() + 1}/${date.getDate()}`;
}

/**
 * Builds the per-line gutter annotations. IDEA annotates every line, so
 * consecutive lines of one commit repeat the same label instead of leaving a
 * blank gutter that reads as missing data. The date leads the label with two
 * spaces before the author, which keeps the two fields visually separate
 * without a punctuation mark that reads as a list.
 */
export function buildGitBlameGutterEntries(
  blame: GitBlame,
  options: { uncommittedLabel: string },
): Map<number, GitBlameGutterEntry> {
  const entries = new Map<number, GitBlameGutterEntry>();
  const lines = [...blame.lines].sort((left, right) => left.line_number - right.line_number);

  for (const line of lines) {
    const label = line.is_uncommitted
      ? options.uncommittedLabel
      : `${formatGitBlameDate(line.time)}  ${line.author}`;
    entries.set(line.line_number, {
      commitHash: line.commit_hash,
      text: label,
      title: line.is_uncommitted ? label : `${label} · ${line.commit_hash.slice(0, 8)}`,
      isUncommitted: line.is_uncommitted,
    });
  }

  return entries;
}

const MIN_COLUMN_CELLS = 12;
const MAX_COLUMN_CELLS = 26;

/** Wide (CJK and fullwidth) glyphs occupy two cells in the gutter column. */
function glyphCells(char: string): number {
  const code = char.codePointAt(0) ?? 0;
  return code >= 0x2e80 && !(code >= 0xff61 && code <= 0xffdc) ? 2 : 1;
}

/**
 * Width of the annotation column in character cells. Sizing it to the longest
 * label keeps short names from reserving a column they never fill, and the cap
 * stops one unusually long author from pushing the numbers away.
 *
 * Monaco sizes the column as `cells × maxDigitWidth` and rounds, while the
 * label is capped by a `ch` subtraction in CSS. Without one spare cell the
 * longest label lands a fraction of a pixel over that cap and renders with an
 * ellipsis, so the number cells are rounded up.
 */
export function gitBlameColumnChars(entries: ReadonlyMap<number, GitBlameGutterEntry>): number {
  let labelCells = 0;
  let lastLine = 1;
  for (const [lineNumber, entry] of entries) {
    lastLine = Math.max(lastLine, lineNumber);
    let cells = 0;
    for (const char of entry.text) cells += glyphCells(char);
    labelCells = Math.max(labelCells, cells);
  }
  const numberCells = Math.max(4, String(lastLine).length) + 1;
  return Math.min(MAX_COLUMN_CELLS, Math.max(MIN_COLUMN_CELLS, labelCells + numberCells));
}

/**
 * Renders one entry for the line-number column. Monaco injects the line-number
 * formatter result as HTML, which is how the annotation sits left of the
 * number instead of replacing it.
 */
export function gitBlameGutterHtml(entry: GitBlameGutterEntry): string {
  const title = entry.title.length > 0 ? ` title="${escapeGitBlameHtml(entry.title)}"` : "";
  return `<span class="lithe-blame"${title}>${escapeGitBlameHtml(entry.text)}</span>`;
}
