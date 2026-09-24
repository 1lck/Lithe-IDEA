export const SIDEBAR_ACTIVITY_ITEM_IDS = [
  "files",
  "git",
  "search",
  "run",
  "terminal",
  "diagnostics",
  "gitLog",
  "settings",
] as const;
export const SIDEBAR_BOTTOM_ACTIVITY_ITEM_IDS = [
  "run",
  "terminal",
  "diagnostics",
  "gitLog",
  "settings",
] as const;
export const FOOTER_LEADING_ITEM_IDS = ["filePath", "branch"] as const;
export const FOOTER_TRAILING_ITEM_IDS = [
  "cursor",
  "encoding",
  "indent",
  "readOnly",
  "memory",
  "gitChanges",
] as const;

export type SidebarActivityItemId = (typeof SIDEBAR_ACTIVITY_ITEM_IDS)[number];
export type FooterLeadingItemId = (typeof FOOTER_LEADING_ITEM_IDS)[number] | "debugger";
export type FooterTrailingItemId = (typeof FOOTER_TRAILING_ITEM_IDS)[number];

interface SidebarActivityVisibilityFeatures {
  search: boolean;
  git: boolean;
  terminal: boolean;
  diagnostics: boolean;
}

export function sidebarActivityVisibilityItemIds(
  features: SidebarActivityVisibilityFeatures,
): SidebarActivityItemId[] {
  return SIDEBAR_ACTIVITY_ITEM_IDS.filter((id) => {
    if (id === "search") return features.search;
    if (id === "git" || id === "gitLog") return features.git;
    if (id === "terminal") return features.terminal;
    if (id === "diagnostics") return features.diagnostics;
    return true;
  });
}

export function setSidebarActivityItemVisibility(
  hiddenItemIds: readonly string[],
  itemId: SidebarActivityItemId,
  visible: boolean,
): string[] {
  return visible
    ? hiddenItemIds.filter((hiddenItemId) => hiddenItemId !== itemId)
    : [...new Set([...hiddenItemIds, itemId])];
}

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
