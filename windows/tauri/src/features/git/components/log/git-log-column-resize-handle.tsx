import { useTranslation } from "@/i18n/locale-provider";
import type { GitLogColumn } from "../../utils/git-log-columns";

/**
 * Drag handle on the left edge of an author or date cell. Every row renders one, so the whole
 * column edge is draggable. It reaches 4px outside the edge and 8px (the cell's text inset) into
 * the cell, so the resize cursor appears right up to the text; it stays unstyled (no highlight)
 * like the app's other splitters.
 */
export function GitLogColumnResizeHandle({
  column,
  onStartResize,
}: {
  column: GitLogColumn;
  onStartResize: (column: GitLogColumn, event: React.PointerEvent) => void;
}) {
  const { t } = useTranslation();

  return (
    <div
      role="separator"
      aria-orientation="vertical"
      aria-label={t(
        column === "author" ? "git.log.resizeAuthorColumn" : "git.log.resizeDateColumn",
      )}
      className="absolute inset-y-0 -left-1 z-10 w-3 cursor-ew-resize"
      onPointerDown={(event) => onStartResize(column, event)}
      // A drag ends with a click on a common ancestor; keep clicks off the row's own handlers.
      onClick={(event) => event.stopPropagation()}
      onDoubleClick={(event) => event.stopPropagation()}
    />
  );
}
