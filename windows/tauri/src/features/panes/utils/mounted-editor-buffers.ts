export interface MountedEditorBufferState {
  mountedIds: readonly string[];
  recentIds: readonly string[];
}

function hasSameMembers(left: readonly string[], right: readonly string[]): boolean {
  if (left.length !== right.length) return false;
  const rightIds = new Set(right);
  return left.every((id) => rightIds.has(id));
}

/**
 * Tracks editor recency without forcing a React update when only LRU order changes.
 * The mounted list is used as a membership set by the renderer, while recentIds
 * preserves ordering for the next capacity eviction.
 */
export function reconcileMountedEditorBuffers(
  previous: MountedEditorBufferState,
  openIds: readonly string[],
  activeId: string | null,
  limit: number,
): MountedEditorBufferState {
  if (limit <= 0) {
    return {
      recentIds: [],
      mountedIds: previous.mountedIds.length === 0 ? previous.mountedIds : [],
    };
  }

  const openIdSet = new Set(openIds);
  const nextRecentIds = [
    ...(activeId && openIdSet.has(activeId) ? [activeId] : []),
    ...previous.recentIds.filter((id) => id !== activeId && openIdSet.has(id)),
  ].slice(0, limit);

  return {
    recentIds: nextRecentIds,
    mountedIds: hasSameMembers(previous.mountedIds, nextRecentIds)
      ? previous.mountedIds
      : nextRecentIds,
  };
}
