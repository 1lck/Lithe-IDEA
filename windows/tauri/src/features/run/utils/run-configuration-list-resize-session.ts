import { clampRunConfigurationListWidth } from "./run-configuration-list-layout";

// The pointer-drag session is shared with other features; re-exported to keep existing imports.
export {
  startDocumentResizeSession,
  type DocumentResizeSession,
  type DocumentResizeSessionOptions,
} from "@/utils/document-resize-session";

/** Matches the file-navigator sidebar keyboard resize step. */
export const RUN_CONFIGURATION_LIST_RESIZE_STEP = 16;

export function nextRunConfigurationListWidthForKey(
  currentWidth: number,
  key: string,
  containerWidth: number,
): number | null {
  if (key !== "ArrowLeft" && key !== "ArrowRight") {
    return null;
  }

  const delta =
    key === "ArrowRight"
      ? RUN_CONFIGURATION_LIST_RESIZE_STEP
      : -RUN_CONFIGURATION_LIST_RESIZE_STEP;
  return clampRunConfigurationListWidth(currentWidth + delta, containerWidth);
}
