/**
 * Splits the notification sources that are currently visible into the ones that
 * appeared just now and the ones that are still on screen.
 *
 * The workbench records notifications from an effect that re-runs whenever the
 * toast list changes, so every source that stays visible is reported again and
 * again. Only the ids returned in `newIds` may raise a merged occurrence count;
 * re-reporting a visible source must never look like a repeat. Ids that left the
 * list are forgotten, so a source that disappears and comes back counts again.
 */
export function partitionNewOccurrences(
  reportedIds: ReadonlySet<string>,
  visibleIds: readonly string[],
): { newIds: Set<string>; reportedIds: Set<string> } {
  const newIds = new Set(visibleIds.filter((id) => !reportedIds.has(id)));

  return { newIds, reportedIds: new Set(visibleIds) };
}
