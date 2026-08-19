interface QueryResultSummaryInput {
  isCustomQuery: boolean;
  rowCount: number;
  currentPage?: number;
  totalPages?: number;
  formatVisibleRows?: (count: number) => string;
  formatQueryRows?: (count: number) => string;
  formatVisibleQueryRowsOnPage?: (count: number, currentPage: number, totalPages: number) => string;
}

function rowNoun(count: number): string {
  return `row${count === 1 ? "" : "s"}`;
}

function normalizePositiveInteger(value: number | undefined, fallback: number): number {
  if (!Number.isFinite(value)) return fallback;
  return Math.max(1, Math.trunc(value ?? fallback));
}

function normalizeNonNegativeInteger(value: number): number {
  return Number.isFinite(value) ? Math.max(0, Math.trunc(value)) : 0;
}

export function formatQueryResultSummary({
  isCustomQuery,
  rowCount,
  currentPage,
  totalPages,
  formatVisibleRows = (count) => `${count} visible ${rowNoun(count)}`,
  formatQueryRows = (count) => `${count} query ${rowNoun(count)}`,
  formatVisibleQueryRowsOnPage = (count, page, pages) =>
    `${count} visible query ${rowNoun(count)} on page ${page} of ${pages}`,
}: QueryResultSummaryInput): string {
  const safeRowCount = normalizeNonNegativeInteger(rowCount);

  if (!isCustomQuery) {
    return formatVisibleRows(safeRowCount);
  }

  const safeTotalPages = normalizePositiveInteger(totalPages, 1);
  if (safeTotalPages <= 1) {
    return formatQueryRows(safeRowCount);
  }

  const safeCurrentPage = Math.min(normalizePositiveInteger(currentPage, 1), safeTotalPages);
  return formatVisibleQueryRowsOnPage(safeRowCount, safeCurrentPage, safeTotalPages);
}
