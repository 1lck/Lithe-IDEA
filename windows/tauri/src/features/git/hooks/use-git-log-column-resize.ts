import { useCallback, useEffect, useMemo, useRef, useState, type CSSProperties } from "react";
import {
  startDocumentResizeSession,
  type DocumentResizeSession,
} from "@/utils/document-resize-session";
import { useGitLogPreferencesStore } from "../stores/git-log-preferences.store";
import {
  GIT_LOG_COLUMN_CSS_VARIABLES,
  GIT_LOG_MESSAGE_MIN_WIDTH,
  clampGitLogColumnWidth,
  type GitLogColumn,
} from "../utils/git-log-columns";

/**
 * Owns the commit table's resizable author and date columns.
 *
 * Widths reach every row through CSS variables on the scroll container. While dragging, the
 * variable is written straight to the DOM (once per frame) so the virtualized rows are not
 * re-rendered; the final width is persisted once when the drag ends.
 */
export function useGitLogColumnResize(scrollRef: React.RefObject<HTMLElement | null>) {
  const authorWidth = useGitLogPreferencesStore.use.authorColumnWidth();
  const dateWidth = useGitLogPreferencesStore.use.dateColumnWidth();
  const { setColumnWidth } = useGitLogPreferencesStore.use.actions();
  const sessionRef = useRef<DocumentResizeSession | null>(null);
  const [activeColumn, setActiveColumn] = useState<GitLogColumn | null>(null);

  const startResize = useCallback(
    (column: GitLogColumn, event: React.PointerEvent) => {
      // Only the primary button resizes; the secondary button must still open the row menu.
      if (event.button !== 0) return;
      event.preventDefault();
      // Keep the row from treating the press as a selection or the start of a double-click open.
      event.stopPropagation();
      sessionRef.current?.dispose({ commit: true });

      const variable = GIT_LOG_COLUMN_CSS_VARIABLES[column];
      sessionRef.current = startDocumentResizeSession({
        startX: event.clientX,
        startWidth: column === "author" ? authorWidth : dateWidth,
        // Both columns hug the right edge, so dragging their left edge leftwards widens them.
        direction: -1,
        cursor: "ew-resize",
        clampWidth: (value) => clampGitLogColumnWidth(column, value),
        applyWidth: (width) => scrollRef.current?.style.setProperty(variable, `${width}px`),
        commitWidth: (width) => {
          setColumnWidth(column, width);
          sessionRef.current = null;
        },
        onActiveChange: (active) => setActiveColumn(active ? column : null),
      });
    },
    [authorWidth, dateWidth, scrollRef, setColumnWidth],
  );

  // Persist an in-flight drag if the table unmounts mid-gesture, and drop listeners and styles.
  useEffect(
    () => () => {
      sessionRef.current?.dispose({ commit: true });
      sessionRef.current = null;
    },
    [],
  );

  const columnStyle = useMemo(
    () =>
      ({
        [GIT_LOG_COLUMN_CSS_VARIABLES.author]: `${authorWidth}px`,
        [GIT_LOG_COLUMN_CSS_VARIABLES.date]: `${dateWidth}px`,
        // Rows never get narrower than their columns plus the message area; overflow scrolls.
        "--git-log-row-min-width": `calc(var(${GIT_LOG_COLUMN_CSS_VARIABLES.author}) + var(${GIT_LOG_COLUMN_CSS_VARIABLES.date}) + ${GIT_LOG_MESSAGE_MIN_WIDTH}px)`,
      }) as CSSProperties,
    [authorWidth, dateWidth],
  );

  return { columnStyle, activeColumn, startResize };
}
