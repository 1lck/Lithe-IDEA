export const HEADER_TRAILING_ITEM_IDS = [] as const;
export const SIDEBAR_ACTIVITY_ITEM_IDS = [
  "files",
  "git",
  "search",
  "database",
  "run",
  "settings",
] as const;
export const FOOTER_LEADING_ITEM_IDS = [
  "branch",
  "gitLog",
  "terminal",
  "diagnostics",
] as const;
export const FOOTER_TRAILING_ITEM_IDS = [
  "databases",
  "notifications",
] as const;

export type HeaderTrailingItemId = "account";
export type SidebarActivityItemId = (typeof SIDEBAR_ACTIVITY_ITEM_IDS)[number];
export type FooterLeadingItemId = (typeof FOOTER_LEADING_ITEM_IDS)[number] | "debugger";
export type FooterTrailingItemId = (typeof FOOTER_TRAILING_ITEM_IDS)[number];

export function normalizeItemOrder<T extends string>(
  persistedOrder: readonly T[] | undefined,
  defaultOrder: readonly T[],
): T[] {
  if (!persistedOrder || persistedOrder.length === 0) {
    return [...defaultOrder];
  }

  const allowedIds = new Set(defaultOrder);
  const seen = new Set<T>();
  const normalized: T[] = [];

  for (const id of persistedOrder) {
    if (!allowedIds.has(id) || seen.has(id)) {
      continue;
    }

    normalized.push(id);
    seen.add(id);
  }

  for (const id of defaultOrder) {
    if (!seen.has(id)) {
      normalized.push(id);
    }
  }

  return normalized;
}
