/** Matches macOS RunView configuration list sizing. */
export const RUN_CONFIGURATION_LIST_DEFAULT_WIDTH = 230;
export const RUN_CONFIGURATION_LIST_MIN_WIDTH = 180;
export const RUN_CONFIGURATION_LIST_MAX_WIDTH = 420;
export const RUN_CONFIGURATION_LIST_MIN_CONTENT_WIDTH = 320;
export const RUN_CONFIGURATION_LIST_HANDLE_THICKNESS = 4;

export function getRunConfigurationListMaxWidth(containerWidth: number): number {
  const available = containerWidth - RUN_CONFIGURATION_LIST_HANDLE_THICKNESS - RUN_CONFIGURATION_LIST_MIN_CONTENT_WIDTH;
  return Math.max(
    RUN_CONFIGURATION_LIST_MIN_WIDTH,
    Math.min(RUN_CONFIGURATION_LIST_MAX_WIDTH, available),
  );
}

export function clampRunConfigurationListWidth(value: number, containerWidth: number): number {
  const maxWidth = getRunConfigurationListMaxWidth(containerWidth);
  const minWidth = Math.min(RUN_CONFIGURATION_LIST_MIN_WIDTH, maxWidth);
  if (!Number.isFinite(value)) {
    return Math.min(RUN_CONFIGURATION_LIST_DEFAULT_WIDTH, maxWidth);
  }
  return Math.max(minWidth, Math.min(value, maxWidth));
}
