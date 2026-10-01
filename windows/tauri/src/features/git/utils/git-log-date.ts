type Translate = (key: string, values?: Record<string, string | number>) => string;

// Matches the `--date=format:%Y/%m/%d %H:%M` strings produced by the Git log commands.
const GIT_LOG_DATE_PATTERN = /^(\d{4})\/(\d{2})\/(\d{2}) (\d{2}):(\d{2})$/;
const MS_PER_MINUTE = 60_000;
const MINUTES_PER_HOUR = 60;

function formatTwelveHourTime(hours: number, minutes: number): string {
  const period = hours < 12 ? "AM" : "PM";
  const displayHour = hours % 12 === 0 ? 12 : hours % 12;
  return `${displayHour}:${String(minutes).padStart(2, "0")} ${period}`;
}

function startOfDay(date: Date): number {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
}

/**
 * Formats a Git log commit date the way IDEA's commit history does: "N minutes ago" within the
 * last hour, "Today"/"Yesterday" with a 12-hour time, and the calendar date with a 12-hour time
 * otherwise. Unparseable input is returned unchanged so unusual backend values stay visible.
 */
export function formatGitLogDate(dateString: string, t: Translate, now: Date = new Date()): string {
  const match = GIT_LOG_DATE_PATTERN.exec(dateString);
  if (!match) return dateString;

  const [year, month, day, hours, minutes] = match.slice(1).map(Number);
  const date = new Date(year, month - 1, day, hours, minutes);
  if (Number.isNaN(date.getTime())) return dateString;

  const elapsedMinutes = Math.floor((now.getTime() - date.getTime()) / MS_PER_MINUTE);
  // Negative values come from clock skew or authors in a later timezone; fall through to the
  // absolute formats instead of showing a nonsensical "-3 minutes ago".
  if (elapsedMinutes >= 0 && elapsedMinutes < MINUTES_PER_HOUR) {
    if (elapsedMinutes < 1) return t("git.log.dateJustNow");
    return t(elapsedMinutes === 1 ? "git.log.dateMinuteAgoOne" : "git.log.dateMinutesAgo", {
      count: elapsedMinutes,
    });
  }

  const time = formatTwelveHourTime(hours, minutes);
  const dayDifference = Math.round((startOfDay(now) - startOfDay(date)) / (24 * 60 * MS_PER_MINUTE));
  if (dayDifference === 0) return t("git.log.dateToday", { time });
  if (dayDifference === 1) return t("git.log.dateYesterday", { time });

  // Field order is locale copy: English reads day/month/year, Chinese year/month/day.
  return t("git.log.dateAbsolute", { year: match[1], month: match[2], day: match[3], time });
}
