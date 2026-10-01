import { useEffect, useRef, useState } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { formatGitLogDate } from "../../utils/git-log-date";

/**
 * Commit date cell of a Git log row. Relative labels ("5 minutes ago", "Today") are computed
 * against the time the row was rendered and refreshed when the pointer enters the row, instead
 * of re-rendering the whole table on a timer.
 */
export function GitLogDateCell({
  date,
  utcOffsetMinutes,
}: {
  date: string;
  utcOffsetMinutes: number | undefined;
}) {
  const { t } = useTranslation();
  const cellRef = useRef<HTMLSpanElement>(null);
  const [now, setNow] = useState(() => new Date());

  useEffect(() => {
    const row = cellRef.current?.closest("[data-git-commit-index]");
    if (!row) return;
    const refresh = () => setNow(new Date());
    row.addEventListener("mouseenter", refresh);
    return () => row.removeEventListener("mouseenter", refresh);
  }, []);

  return (
    <span
      ref={cellRef}
      className="min-w-0 flex-1 overflow-clip px-2 text-ellipsis whitespace-nowrap text-left text-foreground tabular-nums"
    >
      {formatGitLogDate(date, t, utcOffsetMinutes, now)}
    </span>
  );
}
