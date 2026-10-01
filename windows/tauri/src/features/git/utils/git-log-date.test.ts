import { describe, expect, test } from "bun:test";
import { formatGitLogDate } from "./git-log-date";

// Echoes the key and values so assertions stay independent of locale copy.
const t = (key: string, values?: Record<string, string | number>) =>
  values ? `${key}:${JSON.stringify(values)}` : key;

const am = (time: string) => `git.log.timeAm:${JSON.stringify({ time })}`;
const pm = (time: string) => `git.log.timePm:${JSON.stringify({ time })}`;

// Local time on purpose: Git's displayed date is interpreted in the machine's zone, and the
// offset passed alongside it is the local one so relative labels apply.
const now = new Date(2026, 8, 10, 15, 30);
const local = -now.getTimezoneOffset();

describe("formatGitLogDate", () => {
  test("shows minutes ago for commits within the last hour", () => {
    expect(formatGitLogDate("2026/09/10 15:30", t, local, now)).toBe("git.log.dateJustNow");
    expect(formatGitLogDate("2026/09/10 15:29", t, local, now)).toBe(
      'git.log.dateMinuteAgoOne:{"count":1}',
    );
    expect(formatGitLogDate("2026/09/10 15:05", t, local, now)).toBe(
      'git.log.dateMinutesAgo:{"count":25}',
    );
    expect(formatGitLogDate("2026/09/10 14:31", t, local, now)).toBe(
      'git.log.dateMinutesAgo:{"count":59}',
    );
  });

  test("shows Today and Yesterday with a localized 12-hour time once past an hour", () => {
    expect(formatGitLogDate("2026/09/10 14:30", t, local, now)).toBe(
      `git.log.dateToday:${JSON.stringify({ time: pm("2:30") })}`,
    );
    expect(formatGitLogDate("2026/09/10 00:05", t, local, now)).toBe(
      `git.log.dateToday:${JSON.stringify({ time: am("12:05") })}`,
    );
    expect(formatGitLogDate("2026/09/09 23:59", t, local, now)).toBe(
      `git.log.dateYesterday:${JSON.stringify({ time: pm("11:59") })}`,
    );
    expect(formatGitLogDate("2026/09/09 12:00", t, local, now)).toBe(
      `git.log.dateYesterday:${JSON.stringify({ time: pm("12:00") })}`,
    );
  });

  test("shows the calendar date with a 12-hour time for older commits", () => {
    expect(formatGitLogDate("2026/09/08 09:07", t, local, now)).toBe(
      `git.log.dateAbsolute:${JSON.stringify({ year: "2026", month: "09", day: "08", time: am("9:07") })}`,
    );
    expect(formatGitLogDate("2025/12/31 21:45", t, local, now)).toBe(
      `git.log.dateAbsolute:${JSON.stringify({ year: "2025", month: "12", day: "31", time: pm("9:45") })}`,
    );
  });

  test("measures Yesterday by calendar day, not by 24 elapsed hours", () => {
    const justAfterMidnight = new Date(2026, 8, 10, 0, 10);
    expect(formatGitLogDate("2026/09/09 23:50", t, local, justAfterMidnight)).toBe(
      'git.log.dateMinutesAgo:{"count":20}',
    );
    expect(formatGitLogDate("2026/09/09 22:00", t, local, justAfterMidnight)).toBe(
      `git.log.dateYesterday:${JSON.stringify({ time: pm("10:00") })}`,
    );
  });

  // Regression: a commit authored in another zone carries that zone's wall-clock time, so
  // comparing it with local "now" would produce wrong "minutes ago" and "Today" labels.
  test("shows only the calendar date when the author's zone differs or is unknown", () => {
    const absoluteToday = `git.log.dateAbsolute:${JSON.stringify({ year: "2026", month: "09", day: "10", time: pm("3:25") })}`;
    expect(formatGitLogDate("2026/09/10 15:25", t, local + 60, now)).toBe(absoluteToday);
    expect(formatGitLogDate("2026/09/10 15:25", t, null, now)).toBe(absoluteToday);
    expect(formatGitLogDate("2026/09/10 15:25", t, undefined, now)).toBe(absoluteToday);
  });

  test("falls back to absolute formats for future dates and passes bad input through", () => {
    expect(formatGitLogDate("2026/09/10 16:00", t, local, now)).toBe(
      `git.log.dateToday:${JSON.stringify({ time: pm("4:00") })}`,
    );
    expect(formatGitLogDate("not a date", t, local, now)).toBe("not a date");
  });
});
