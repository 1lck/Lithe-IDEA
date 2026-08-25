export type NavigationLocationPresentation = "empty" | "direct" | "list";

/** Selects direct navigation unless the caller explicitly supports an ambiguity chooser. */
export function navigationLocationPresentation(
  locationCount: number,
  showMultipleResults = false,
): NavigationLocationPresentation {
  if (locationCount <= 0) return "empty";
  if (locationCount > 1 && showMultipleResults) return "list";
  return "direct";
}
