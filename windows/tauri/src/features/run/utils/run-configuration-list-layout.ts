/** Matches macOS RunView configuration list sizing. */
export const RUN_CONFIGURATION_LIST_DEFAULT_WIDTH = 230;
export const RUN_CONFIGURATION_LIST_MIN_WIDTH = 180;
export const RUN_CONFIGURATION_LIST_MAX_WIDTH = 420;
export const RUN_CONFIGURATION_LIST_MIN_CONTENT_WIDTH = 320;
export const RUN_CONFIGURATION_LIST_HANDLE_THICKNESS = 4;
export const RUN_LANGUAGE_COLUMN_WIDTH = 144;
export const RUN_LANGUAGE_COLUMN_COMPACT_WIDTH = 32;
export const RUN_LANGUAGE_COLUMN_MIN_WIDTH = 112;
export const RUN_LANGUAGE_COLUMN_MAX_WIDTH = 240;
export const RUN_LANGUAGE_COLUMN_COLLAPSE_THRESHOLD = 80;
export const RUN_LANGUAGE_COLUMN_EXPAND_THRESHOLD = 96;

/** Different thresholds keep small pointer movements from repeatedly toggling the rail. */
export function runLanguageColumnDragWidth(
  value: number,
  containerWidth: number,
  compact: boolean,
): number {
  const threshold = compact
    ? RUN_LANGUAGE_COLUMN_EXPAND_THRESHOLD
    : RUN_LANGUAGE_COLUMN_COLLAPSE_THRESHOLD;
  return getRunLanguageColumnWidth(containerWidth, value, value < threshold);
}

export function getRunLanguageColumnMaxWidth(containerWidth: number): number {
  return Math.max(
    0,
    Math.min(
      RUN_LANGUAGE_COLUMN_MAX_WIDTH,
      containerWidth -
        RUN_CONFIGURATION_LIST_MIN_WIDTH -
        2 * RUN_CONFIGURATION_LIST_HANDLE_THICKNESS -
        RUN_CONFIGURATION_LIST_MIN_CONTENT_WIDTH,
    ),
  );
}

export function getRunLanguageColumnWidth(
  containerWidth: number,
  preferredWidth = RUN_LANGUAGE_COLUMN_WIDTH,
  collapsed = false,
): number {
  const maxWidth = getRunLanguageColumnMaxWidth(containerWidth);
  if (collapsed || maxWidth < RUN_LANGUAGE_COLUMN_MIN_WIDTH) {
    return RUN_LANGUAGE_COLUMN_COMPACT_WIDTH;
  }
  return Math.max(
    RUN_LANGUAGE_COLUMN_MIN_WIDTH,
    Math.min(
      Number.isFinite(preferredWidth) ? preferredWidth : RUN_LANGUAGE_COLUMN_WIDTH,
      maxWidth,
    ),
  );
}

export function getRunConfigurationListMaxWidth(containerWidth: number): number {
  const available =
    containerWidth -
    RUN_CONFIGURATION_LIST_HANDLE_THICKNESS -
    RUN_CONFIGURATION_LIST_MIN_CONTENT_WIDTH;
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
