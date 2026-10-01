export type GitLogColumn = "author" | "date";

export interface GitLogColumnWidths {
  author: number;
  date: number;
}

export const GIT_LOG_COLUMN_DEFAULT_WIDTHS: GitLogColumnWidths = { author: 112, date: 144 };

// Bounds keep a column readable and stop a runaway drag from pushing the commit message out.
const GIT_LOG_COLUMN_MIN_WIDTHS: GitLogColumnWidths = { author: 56, date: 72 };
const GIT_LOG_COLUMN_MAX_WIDTHS: GitLogColumnWidths = { author: 360, date: 280 };

/**
 * Width reserved for the graph and commit message, on top of both columns and the row padding.
 * It equals the previous fixed 520px row minimum minus the default author and date widths.
 */
export const GIT_LOG_MESSAGE_MIN_WIDTH = 280;

/** CSS variables carrying the live column widths; set on the table's scroll container. */
export const GIT_LOG_COLUMN_CSS_VARIABLES: Record<GitLogColumn, string> = {
  author: "--git-log-author-width",
  date: "--git-log-date-width",
};

export function clampGitLogColumnWidth(column: GitLogColumn, width: number): number {
  if (!Number.isFinite(width)) return GIT_LOG_COLUMN_DEFAULT_WIDTHS[column];
  return Math.round(
    Math.min(
      Math.max(width, GIT_LOG_COLUMN_MIN_WIDTHS[column]),
      GIT_LOG_COLUMN_MAX_WIDTHS[column],
    ),
  );
}

/** Restores a persisted width, falling back to the default for missing or corrupt values. */
export function normalizeGitLogColumnWidth(column: GitLogColumn, width: unknown): number {
  return typeof width === "number"
    ? clampGitLogColumnWidth(column, width)
    : GIT_LOG_COLUMN_DEFAULT_WIDTHS[column];
}
