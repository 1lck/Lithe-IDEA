import { useCallback, useEffect, useMemo, useRef, useState, type CSSProperties } from "react";
import {
  startDocumentResizeSession,
  type DocumentResizeSession,
  type DocumentResizeSessionOptions,
} from "@/utils/document-resize-session";
import {
  COMMIT_MESSAGE_MIN_HEIGHT,
  clampCommitMessageHeight,
  useGitCommitPanelPreferencesStore,
} from "../stores/git-commit-panel-preferences.store";

export const COMMIT_MESSAGE_HEIGHT_CSS_VARIABLE = "--git-commit-message-height";
/** The changes list never gets shorter than this while the commit area grows. */
export const GIT_CHANGES_MIN_HEIGHT = 96;
const KEYBOARD_STEP = 16;

/**
 * Owns the divider between the changes list and the commit area.
 *
 * Dragging resizes the commit message editor through a CSS variable on the commit area,
 * written once per frame so the Commit panel does not re-render; the final height is
 * persisted once when the drag ends. The changes list keeps at least
 * `GIT_CHANGES_MIN_HEIGHT`, measured when the drag starts.
 */
export function useGitCommitAreaResize(
  commitAreaRef: React.RefObject<HTMLElement | null>,
  changesRef: React.RefObject<HTMLElement | null>,
  frameScheduler?: Pick<DocumentResizeSessionOptions, "scheduleFrame" | "cancelFrame">,
) {
  const height = useGitCommitPanelPreferencesStore.use.commitMessageHeight();
  const { setCommitMessageHeight } = useGitCommitPanelPreferencesStore.use.actions();
  const sessionRef = useRef<DocumentResizeSession | null>(null);
  const [isResizing, setIsResizing] = useState(false);

  const maxHeightFor = useCallback(
    (currentHeight: number) => {
      const changesHeight = changesRef.current?.getBoundingClientRect().height ?? 0;
      return Math.max(
        COMMIT_MESSAGE_MIN_HEIGHT,
        currentHeight + Math.max(0, changesHeight - GIT_CHANGES_MIN_HEIGHT),
      );
    },
    [changesRef],
  );

  const startResize = useCallback(
    (event: React.PointerEvent) => {
      if (event.button !== 0) return;
      event.preventDefault();
      sessionRef.current?.dispose({ commit: true });
      const maxHeight = maxHeightFor(height);

      sessionRef.current = startDocumentResizeSession({
        axis: "y",
        startX: event.clientY,
        startWidth: height,
        // The divider sits above the commit area, so dragging it up grows the editor.
        direction: -1,
        cursor: "ns-resize",
        clampWidth: (value) => Math.min(maxHeight, clampCommitMessageHeight(value)),
        applyWidth: (value) =>
          commitAreaRef.current?.style.setProperty(COMMIT_MESSAGE_HEIGHT_CSS_VARIABLE, `${value}px`),
        commitWidth: (value) => {
          setCommitMessageHeight(value);
          sessionRef.current = null;
        },
        onActiveChange: setIsResizing,
        ...frameScheduler,
      });
    },
    [commitAreaRef, frameScheduler, height, maxHeightFor, setCommitMessageHeight],
  );

  const handleKeyDown = useCallback(
    (event: React.KeyboardEvent) => {
      const delta =
        event.key === "ArrowUp" ? KEYBOARD_STEP : event.key === "ArrowDown" ? -KEYBOARD_STEP : 0;
      if (delta === 0) return;
      event.preventDefault();
      setCommitMessageHeight(Math.min(maxHeightFor(height), clampCommitMessageHeight(height + delta)));
    },
    [height, maxHeightFor, setCommitMessageHeight],
  );

  // Persist an in-flight drag if the view unmounts mid-gesture, and drop listeners and styles.
  useEffect(
    () => () => {
      sessionRef.current?.dispose({ commit: true });
      sessionRef.current = null;
    },
    [],
  );

  const commitAreaStyle = useMemo(
    () => ({ [COMMIT_MESSAGE_HEIGHT_CSS_VARIABLE]: `${height}px` }) as CSSProperties,
    [height],
  );

  return { commitAreaStyle, commitMessageHeight: height, isResizing, startResize, handleKeyDown };
}
