import { formatLocaleDateTime, type DateTimePresentation } from "@/platform/system-date-time";

type Translate = (key: string, values?: Record<string, string | number>) => string;
const GIT_LOG_DATE_PATTERN = /^(\d{4})\/(\d{2})\/(\d{2}) (\d{2}):(\d{2})$/;
const MS_PER_MINUTE = 60_000;

/** Core preserves the author's wall-clock date and UTC offset. Recover its absolute instant. */
export function parseGitLogDate(
  dateString: string,
  utcOffsetMinutes: number | null | undefined,
): Date | null {
  const match = GIT_LOG_DATE_PATTERN.exec(dateString);
  if (!match) return null;
  const [year, month, day, hours, minutes] = match.slice(1).map(Number);
  const wallClock = new Date(0);
  wallClock.setUTCFullYear(year, month - 1, day);
  wallClock.setUTCHours(hours, minutes, 0, 0);
  // Date normalizes impossible dates; reject them instead of silently changing the commit date.
  if (
    wallClock.getUTCFullYear() !== year ||
    wallClock.getUTCMonth() !== month - 1 ||
    wallClock.getUTCDate() !== day ||
    wallClock.getUTCHours() !== hours ||
    wallClock.getUTCMinutes() !== minutes
  )
    return null;
  if (utcOffsetMinutes == null) {
    const local = new Date(0);
    local.setFullYear(year, month - 1, day);
    local.setHours(hours, minutes, 0, 0);
    return local;
  }
  if (!Number.isInteger(utcOffsetMinutes) || Math.abs(utcOffsetMinutes) > 24 * 60) return null;
  return new Date(wallClock.getTime() - utcOffsetMinutes * MS_PER_MINUTE);
}

function calendarDay(date: Date): number {
  return Date.UTC(date.getFullYear(), date.getMonth(), date.getDate());
}

/** IDEA's relative labels use the local calendar; absolute date/time comes from the platform. */
export function formatGitLogDate(
  dateString: string,
  t: Translate,
  utcOffsetMinutes: number | null | undefined,
  now: Date = new Date(),
  presentation?: DateTimePresentation,
): string {
  const date = parseGitLogDate(dateString, utcOffsetMinutes);
  if (!date) return dateString;
  const { date: calendarDate, time } = presentation ?? formatLocaleDateTime(date);
  const absolute = `${calendarDate} ${time}`;
  // Legacy dates have no absolute instant, so relative labels would claim information we lack.
  if (utcOffsetMinutes == null) return absolute;

  const elapsedMinutes = Math.floor((now.getTime() - date.getTime()) / MS_PER_MINUTE);
  if (elapsedMinutes >= 0 && elapsedMinutes < 60) {
    if (elapsedMinutes < 1) return t("git.log.dateJustNow");
    return t(elapsedMinutes === 1 ? "git.log.dateMinuteAgoOne" : "git.log.dateMinutesAgo", {
      count: elapsedMinutes,
    });
  }
  const dayDifference = (calendarDay(now) - calendarDay(date)) / (24 * 60 * MS_PER_MINUTE);
  if (dayDifference === 0) return t("git.log.dateToday", { time });
  if (dayDifference === 1) return t("git.log.dateYesterday", { time });
  return absolute;
}
