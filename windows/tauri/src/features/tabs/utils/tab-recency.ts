import type { TabLimitPolicy } from "@/features/settings/types/settings.types";

/**
 * Order in which tabs were last activated, used to pick which tab closes when
 * the tab limit is exceeded. Kept outside the buffer store: activation order is
 * not document state and must not trigger renders or be persisted.
 */
const lastActivated = new Map<string, number>();
let activationClock = 0;

export function markTabActivated(bufferId: string): void {
  lastActivated.set(bufferId, ++activationClock);
}

export function forgetTab(bufferId: string): void {
  lastActivated.delete(bufferId);
}

/**
 * Orders closable tabs so the first ones are closed first. Tabs never
 * activated in this session count as least recently used, in open order.
 */
export function orderTabsForClosing<T extends { id: string }>(
  tabs: readonly T[],
  policy: TabLimitPolicy,
): T[] {
  if (policy === "oldestOpened") return [...tabs];
  return tabs
    .map((tab, index) => ({ tab, index, used: lastActivated.get(tab.id) ?? 0 }))
    .sort((left, right) => left.used - right.used || left.index - right.index)
    .map(({ tab }) => tab);
}

export function resetTabRecencyForTests(): void {
  lastActivated.clear();
  activationClock = 0;
}
