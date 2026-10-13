import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
} from "react";
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
/** The editor never renders taller than this share of the viewport, whatever height is stored. */
export const COMMIT_MESSAGE_MAX_VIEWPORT_RATIO = 0.6;

/**
 * Height the commit message editor actually has on screen. The stored height can exceed
 * the viewport cap after the window shrinks, so dragging and keyboard steps start from this
 * value; otherwise the first stretch of movement would change nothing visible.
 */
export function visibleCommitMessageHeight(storedHeight: number): number {
  const viewportHeight = globalThis.innerHeight;
  if (!Number.isFinite(viewportHeight) || viewportHeight <= 0) return storedHeight;
  return Math.min(storedHeight, Math.floor(viewportHeight * COMMIT_MESSAGE_MAX_VIEWPORT_RATIO));
}

/**
 * Owns the divider between the changes list and the commit area.
 *
 * Dragging resizes the commit message editor through a CSS variable on the commit area,
 * written once per frame so the Commit panel does not re-render; the final height is
 * persisted once when the drag ends. The changes list keeps at least
 * `GIT_CHANGES_MIN_HEIGHT`, including after the available pane height changes.
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

  const availableHeightRef = useRef(Number.POSITIVE_INFINITY);

  // Observe both the pane and footer: button wrapping, errors and review controls
  // consume space independently of the window size. Only the rendered cap changes;
  // shrinking a pane must not overwrite the user's persisted height preference.
  useLayoutEffect(() => {
    const area = commitAreaRef.current;
    const pane = area?.parentElement;
    const editor = area?.querySelector("textarea");
    if (!area || !pane || !editor) return;
    const measure = () => {
      const paneHeight = pane.getBoundingClientRect().height;
      if (paneHeight <= 0) return; // Hidden panes are measured again when shown.
      const chromeHeight =
        area.getBoundingClientRect().height - editor.getBoundingClientRect().height;
      const maximum = Math.max(
        COMMIT_MESSAGE_MIN_HEIGHT,
        paneHeight - chromeHeight - GIT_CHANGES_MIN_HEIGHT,
      );
      availableHeightRef.current = maximum;
      const value = `${maximum}px`;
      if (area.style.getPropertyValue("--git-commit-message-max-height") !== value) {
        area.style.setProperty("--git-commit-message-max-height", value);
      }
    };
    measure();
    const observer = typeof ResizeObserver === "undefined" ? null : new ResizeObserver(measure);
    observer?.observe(pane);
    observer?.observe(area);
    return () => observer?.disconnect();
  });

  const renderedHeight = useCallback(() => {
    const measured = commitAreaRef.current
      ?.querySelector("textarea")
      ?.getBoundingClientRect().height;
    return measured && measured > 0
      ? measured
      : Math.min(visibleCommitMessageHeight(height), availableHeightRef.current);
  }, [commitAreaRef, height]);

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
      const startHeight = renderedHeight();
      const maxHeight = maxHeightFor(startHeight);

      sessionRef.current = startDocumentResizeSession({
        axis: "y",
        startX: event.clientY,
        startWidth: startHeight,
        // The divider sits above the commit area, so dragging it up grows the editor.
        direction: -1,
        cursor: "ns-resize",
        clampWidth: (value) =>
          Math.min(
            maxHeight,
            availableHeightRef.current,
            visibleCommitMessageHeight(clampCommitMessageHeight(value)),
          ),
        applyWidth: (value) =>
          commitAreaRef.current?.style.setProperty(
            COMMIT_MESSAGE_HEIGHT_CSS_VARIABLE,
            `${value}px`,
          ),
        commitWidth: (value) => {
          setCommitMessageHeight(value);
          sessionRef.current = null;
        },
        onActiveChange: setIsResizing,
        ...frameScheduler,
      });
    },
    [commitAreaRef, frameScheduler, renderedHeight, maxHeightFor, setCommitMessageHeight],
  );

  const handleKeyDown = useCallback(
    (event: React.KeyboardEvent) => {
      const delta =
        event.key === "ArrowUp" ? KEYBOARD_STEP : event.key === "ArrowDown" ? -KEYBOARD_STEP : 0;
      if (delta === 0) return;
      event.preventDefault();
      const visibleHeight = renderedHeight();
      setCommitMessageHeight(
        Math.min(maxHeightFor(visibleHeight), clampCommitMessageHeight(visibleHeight + delta)),
      );
    },
    [renderedHeight, maxHeightFor, setCommitMessageHeight],
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
