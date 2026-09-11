const TOOLBAR_VERTICAL_PADDING = 8;
const TOOLBAR_ACTION_SIZE = 32;
const TOOLBAR_SECTION_SEPARATOR_SIZE = 9;

/** Returns the leading action count that fits while reserving one overflow button. */
export function getVisibleGitReferenceToolbarActionCount(
  containerHeight: number,
  actionCount: number,
): number {
  const normalizedActionCount = Math.max(0, Math.floor(actionCount));
  if (normalizedActionCount === 0 || !Number.isFinite(containerHeight)) return 0;

  const fullToolbarHeight =
    TOOLBAR_VERTICAL_PADDING +
    normalizedActionCount * TOOLBAR_ACTION_SIZE +
    TOOLBAR_SECTION_SEPARATOR_SIZE;
  if (containerHeight >= fullToolbarHeight) return normalizedActionCount;

  const availableSlots = Math.max(
    0,
    Math.floor((Math.max(0, containerHeight) - TOOLBAR_VERTICAL_PADDING) / TOOLBAR_ACTION_SIZE),
  );
  return Math.min(normalizedActionCount - 1, Math.max(0, availableSlots - 1));
}
