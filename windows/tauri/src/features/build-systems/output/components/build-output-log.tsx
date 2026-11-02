import { useEffect, useRef } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { cn } from "@/utils/cn";
import type { BuildOutputLine } from "../build-output-store";

/** Rows rendered per pass; the store budget already bounds the data. */
export const MAX_LOG_ROWS = 2000;
/** Pixel window in which new output keeps the view glued to the bottom. */
const FOLLOW_THRESHOLD_PX = 48;

/**
 * Bounded console log of one build run: interleaved stdout/stderr in arrival
 * order, stderr kept visibly distinct, a truncation notice when the store's
 * line/UTF-8 byte budgets evicted earlier output, and an inline marker on
 * single lines the per-line cap clipped. The container follows the newest
 * line only while the user stayed near the bottom, so scrolling back keeps
 * the position.
 */
export default function BuildOutputLog({
  lines,
  droppedLines,
}: {
  lines: BuildOutputLine[];
  droppedLines: number;
}) {
  const { t } = useTranslation();
  const containerRef = useRef<HTMLDivElement | null>(null);
  const followRef = useRef(true);

  useEffect(() => {
    const container = containerRef.current;
    if (!container || !followRef.current) return;
    container.scrollTop = container.scrollHeight;
  }, [lines]);

  const onScroll = () => {
    const container = containerRef.current;
    if (!container) return;
    followRef.current =
      container.scrollHeight - container.scrollTop - container.clientHeight <= FOLLOW_THRESHOLD_PX;
  };

  const visible = lines.length > MAX_LOG_ROWS ? lines.slice(lines.length - MAX_LOG_ROWS) : lines;
  const hiddenRows = lines.length - visible.length;

  return (
    <div
      ref={containerRef}
      role="log"
      tabIndex={0}
      aria-label={t("buildOutput.logLabel")}
      onScroll={onScroll}
      className="font-mono min-h-0 flex-1 overflow-y-auto overflow-x-hidden px-2 py-1 ui-text-sm leading-relaxed"
    >
      {(droppedLines > 0 || hiddenRows > 0) && (
        <p
          className="whitespace-pre-wrap break-words text-muted-foreground"
          data-slot="log-truncated"
        >
          {t("buildOutput.truncatedLines", {
            count: droppedLines + hiddenRows,
          })}
        </p>
      )}
      {visible.map((line) => (
        <p
          key={line.seq}
          data-stream={line.stream}
          className={cn(
            "whitespace-pre-wrap break-words",
            line.stream === "stderr" ? "text-destructive" : "text-foreground",
          )}
        >
          <span className="select-none text-muted-foreground">{line.stream}: </span>
          {line.text}
          {line.clipped ? "…" : ""}
        </p>
      ))}
    </div>
  );
}
