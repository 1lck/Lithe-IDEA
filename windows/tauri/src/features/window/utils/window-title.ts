import { getBufferById } from "@/features/editor/utils/buffer-index";
import { isVirtualContent, type PaneContent } from "@/features/panes/types/pane-content.types";
import { getProjectDisplayLabel, type ProjectDisplayLabelSource } from "./project-display-label";

/** Fallback title mirroring the bundled window title before a project opens. */
export const DEFAULT_WINDOW_TITLE = "Lithe";

/** IntelliJ-style separator between the project and file segments of the window title. */
const TITLE_SEGMENT_SEPARATOR = " – ";

/**
 * Resolve the file-name segment for the native window title from the active
 * editor buffer. Tool tabs (terminal, search, welcome, ...) and buffers without
 * a backing path yield null so the title falls back to the project name only.
 */
export function getActiveFileTitleSegment(
  buffers: readonly PaneContent[],
  activeBufferId: string | null | undefined,
): string | null {
  const buffer = getBufferById(buffers, activeBufferId);
  if (!buffer || isVirtualContent(buffer) || !buffer.path) {
    return null;
  }

  const name = buffer.name.trim();
  return name.length > 0 ? name : null;
}

/**
 * Compose the native window title shown by the Windows taskbar preview and
 * Alt+Tab: `project – file` when a file is open in the editor area, the
 * project name alone otherwise, and the bundled product name without either.
 */
export function composeWindowTitle(
  activeProject: ProjectDisplayLabelSource | null | undefined,
  activeFileName: string | null | undefined,
): string {
  const segments: string[] = [];

  if (activeProject) {
    const projectLabel = getProjectDisplayLabel(activeProject).trim();
    if (projectLabel.length > 0) {
      segments.push(projectLabel);
    }
  }

  if (activeFileName) {
    segments.push(activeFileName);
  }

  if (segments.length === 0) {
    return DEFAULT_WINDOW_TITLE;
  }

  return segments.join(TITLE_SEGMENT_SEPARATOR);
}
