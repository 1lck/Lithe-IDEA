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
 * Formats the authoring date the way IDEA and macOS annotate a line: an
 * absolute, app-language date instead of a relative one, so a stale
 * annotation cannot read as "3 days ago" forever.
 */
export function formatGitBlameDate(unixSeconds: number, language: string): string {
  if (!Number.isFinite(unixSeconds) || unixSeconds <= 0) return "";
  return new Intl.DateTimeFormat(language, {
    year: "numeric",
    month: "numeric",
    day: "numeric",
  }).format(new Date(unixSeconds * 1000));
}

/**
 * Builds the per-line gutter annotations. IDEA annotates every line, so
 * consecutive lines of one commit repeat the same label instead of leaving a
 * blank gutter that reads as missing data.
 */
export function buildGitBlameGutterEntries(
  blame: GitBlame,
  options: { language: string; uncommittedLabel: string },
): Map<number, GitBlameGutterEntry> {
  const entries = new Map<number, GitBlameGutterEntry>();
  const lines = [...blame.lines].sort((left, right) => left.line_number - right.line_number);

  for (const line of lines) {
    const label = line.is_uncommitted
      ? options.uncommittedLabel
      : `${line.author}, ${formatGitBlameDate(line.time, options.language)}`;
    entries.set(line.line_number, {
      commitHash: line.commit_hash,
      text: label,
      title: line.is_uncommitted ? label : `${label} · ${line.commit_hash.slice(0, 8)}`,
      isUncommitted: line.is_uncommitted,
    });
  }

  return entries;
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
