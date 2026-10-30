import { isSingletonToolBuffer } from "@/features/panes/constants/tool-buffers";
import { isEditorContent, type PaneContent } from "@/features/panes/types/pane-content.types";
import type { TabLimitPolicy } from "@/features/settings/types/settings.types";
import { orderTabsForClosing } from "@/features/tabs/utils/tab-recency";

const AUTO_EVICTION_PROTECTED_TYPES = new Set<PaneContent["type"]>([
  "agent",
  "agentConversation",
  "externalEditor",
  "terminal",
  "webViewer",
]);

export interface AutoEvictionOptions {
  includePreviews?: boolean;
  policy?: TabLimitPolicy;
}

function canAutoEvictBuffer(
  buffer: PaneContent,
  { includePreviews = true }: AutoEvictionOptions = {},
): boolean {
  if (buffer.isPinned) return false;
  if (isEditorContent(buffer) && buffer.isDirty) return false;
  if (!includePreviews && buffer.isPreview) return false;
  if (isSingletonToolBuffer(buffer)) return false;
  return !AUTO_EVICTION_PROTECTED_TYPES.has(buffer.type);
}

/**
 * Picks the tabs to close so at most `maxOpenTabs` auto-closable tabs remain,
 * first ones first. The limit counts only tabs it may close: pinned and unsaved
 * tabs, terminals and agents neither count nor close, and 0 means no limit.
 * `reservedSlots` makes room for tabs about to open.
 */
export function selectBuffersOverTabLimit(
  buffers: PaneContent[],
  maxOpenTabs: number,
  {
    keepBufferId = null,
    reservedSlots = 0,
    ...options
  }: AutoEvictionOptions & { keepBufferId?: string | null; reservedSlots?: number } = {},
): PaneContent[] {
  if (maxOpenTabs <= 0) return [];
  const candidates = buffers.filter((buffer) => canAutoEvictBuffer(buffer, options));
  const excess = candidates.length + reservedSlots - maxOpenTabs;
  if (excess <= 0) return [];
  return orderTabsForClosing(
    candidates.filter((buffer) => buffer.id !== keepBufferId),
    options.policy ?? "leastRecentlyUsed",
  ).slice(0, excess);
}

export function evictLeastRecentAutoClosableBuffer(
  buffers: PaneContent[],
  maxOpenTabs: number,
  options: AutoEvictionOptions = {},
): { buffers: PaneContent[]; evictedBuffer: PaneContent | null } {
  const [evictedBuffer] = selectBuffersOverTabLimit(buffers, maxOpenTabs, {
    ...options,
    reservedSlots: 1,
  });
  if (!evictedBuffer) {
    return { buffers, evictedBuffer: null };
  }

  return {
    buffers: buffers.filter((buffer) => buffer.id !== evictedBuffer.id),
    evictedBuffer,
  };
}
