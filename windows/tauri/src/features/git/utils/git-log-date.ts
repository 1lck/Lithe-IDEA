type Translate = (key: string, values?: Record<string, string | number>) => string;

// Matches the displayed part of Core's `--date=format:%Y/%m/%d %H:%M %z` commit dates; Core
// moves the `%z` offset into `dateUtcOffsetMinutes`.
const GIT_LOG_DATE_PATTERN = /^(\d{4})\/(\d{2})\/(\d{2}) (\d{2}):(\d{2})$/;
const MS_PER_MINUTE = 60_000;
const MINUTES_PER_HOUR = 60;

function formatTwelveHourTime(hours: number, minutes: number, t: Translate): string {
  const displayHour = hours % 12 === 0 ? 12 : hours % 12;
  const time = `${displayHour}:${String(minutes).padStart(2, "0")}`;
  // The period word and its position are locale copy: "2:30 PM" in English, "下午 2:30" in Chinese.
  return t(hours < 12 ? "git.log.timeAm" : "git.log.timePm", { time });
}

function startOfDay(date: Date): number {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
}

/**
 * Formats a Git log commit date the way IDEA's commit history does: "N minutes ago" within the
 * last hour, "Today"/"Yesterday" with a 12-hour time, and the calendar date with a 12-hour time
 * otherwise. Unparseable input is returned unchanged so unusual backend values stay visible.
 *
 * Git reports the date in the author's time zone. Relative labels are only meaningful when that
 * zone matches the local one, so a missing or different `utcOffsetMinutes` always produces the
 * calendar date.
 */
export function formatGitLogDate(
  dateString: string,
  t: Translate,
  utcOffsetMinutes: number | null | undefined,
  now: Date = new Date(),
): string {
  const match = GIT_LOG_DATE_PATTERN.exec(dateString);
  if (!match) return dateString;

  const [year, month, day, hours, minutes] = match.slice(1).map(Number);
  const date = new Date(year, month - 1, day, hours, minutes);
  if (Number.isNaN(date.getTime())) return dateString;

  const time = formatTwelveHourTime(hours, minutes, t);
  const absolute = () =>
    // Field order is locale copy: English reads day/month/year, Chinese year/month/day.
    t("git.log.dateAbsolute", { year: match[1], month: match[2], day: match[3], time });

  // `getTimezoneOffset` is minutes west of UTC; Core reports minutes east.
  const isLocalTimeZone = utcOffsetMinutes != null && utcOffsetMinutes === -date.getTimezoneOffset();
  if (!isLocalTimeZone) return absolute();

  const elapsedMinutes = Math.floor((now.getTime() - date.getTime()) / MS_PER_MINUTE);
  // Negative values come from clock skew; fall through to the absolute formats instead of
  // showing a nonsensical "-3 minutes ago".
  if (elapsedMinutes >= 0 && elapsedMinutes < MINUTES_PER_HOUR) {
    if (elapsedMinutes < 1) return t("git.log.dateJustNow");
    return t(elapsedMinutes === 1 ? "git.log.dateMinuteAgoOne" : "git.log.dateMinutesAgo", {
      count: elapsedMinutes,
    });
  }

  const dayDifference = Math.round((startOfDay(now) - startOfDay(date)) / (24 * 60 * MS_PER_MINUTE));
  if (dayDifference === 0) return t("git.log.dateToday", { time });
  if (dayDifference === 1) return t("git.log.dateYesterday", { time });
  return absolute();
}
