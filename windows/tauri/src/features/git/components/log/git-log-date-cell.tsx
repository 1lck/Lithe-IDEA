import { useEffect, useMemo, useRef, useState } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { formatGitLogDate, parseGitLogDate } from "../../utils/git-log-date";
import {
  formatLocaleDateTime,
  loadSystemDateTime,
  type DateTimePresentation,
} from "@/platform/system-date-time";

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
  const { t, language } = useTranslation();
  const cellRef = useRef<HTMLSpanElement>(null);
  const [now, setNow] = useState(() => new Date());
  const timestamp = parseGitLogDate(date, utcOffsetMinutes)?.getTime();
  const [nativeDateTime, setNativeDateTime] = useState<{
    timestamp: number;
    presentation: DateTimePresentation;
  } | null>(null);

  useEffect(() => {
    if (timestamp == null || language !== "en-US") return;
    let active = true;
    loadSystemDateTime(timestamp)
      .then((presentation) => {
        if (active) setNativeDateTime({ timestamp, presentation });
      })
      .catch((error: unknown) => {
        console.error("Could not read the system date/time format", error);
      });
    return () => {
      active = false;
    };
  }, [timestamp, language]);

  const presentation = useMemo(
    () =>
      timestamp == null
        ? undefined
        : language === "en-US" && nativeDateTime?.timestamp === timestamp
          ? nativeDateTime.presentation
          : formatLocaleDateTime(new Date(timestamp), language === "en-US" ? undefined : language),
    [timestamp, language, nativeDateTime],
  );

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
      className="git-log-commit-text min-w-0 flex-1 overflow-clip px-2 text-ellipsis whitespace-nowrap text-left text-foreground tabular-nums"
    >
      {formatGitLogDate(date, t, utcOffsetMinutes, now, presentation)}
    </span>
  );
}
