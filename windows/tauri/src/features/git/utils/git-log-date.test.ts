import { describe, expect, test } from "bun:test";
import { formatGitLogDate } from "./git-log-date";

// Echoes the key and values so assertions stay independent of locale copy.
const t = (key: string, values?: Record<string, string | number>) =>
  values ? `${key}:${JSON.stringify(values)}` : key;

// Local time on purpose: the formatter interprets Git's zone-less date as local time.
const now = new Date(2026, 8, 10, 15, 30);

describe("formatGitLogDate", () => {
  test("shows minutes ago for commits within the last hour", () => {
    expect(formatGitLogDate("2026/09/10 15:30", t, now)).toBe("git.log.dateJustNow");
    expect(formatGitLogDate("2026/09/10 15:29", t, now)).toBe(
      'git.log.dateMinuteAgoOne:{"count":1}',
    );
    expect(formatGitLogDate("2026/09/10 15:05", t, now)).toBe(
      'git.log.dateMinutesAgo:{"count":25}',
    );
    expect(formatGitLogDate("2026/09/10 14:31", t, now)).toBe(
      'git.log.dateMinutesAgo:{"count":59}',
    );
  });

  test("shows Today and Yesterday with a 12-hour time once past an hour", () => {
    expect(formatGitLogDate("2026/09/10 14:30", t, now)).toBe(
      'git.log.dateToday:{"time":"2:30 PM"}',
    );
    expect(formatGitLogDate("2026/09/10 00:05", t, now)).toBe(
      'git.log.dateToday:{"time":"12:05 AM"}',
    );
    expect(formatGitLogDate("2026/09/09 23:59", t, now)).toBe(
      'git.log.dateYesterday:{"time":"11:59 PM"}',
    );
    expect(formatGitLogDate("2026/09/09 12:00", t, now)).toBe(
      'git.log.dateYesterday:{"time":"12:00 PM"}',
    );
  });

  test("shows the calendar date with a 12-hour time for older commits", () => {
    expect(formatGitLogDate("2026/09/08 09:07", t, now)).toBe(
      'git.log.dateAbsolute:{"year":"2026","month":"09","day":"08","time":"9:07 AM"}',
    );
    expect(formatGitLogDate("2025/12/31 21:45", t, now)).toBe(
      'git.log.dateAbsolute:{"year":"2025","month":"12","day":"31","time":"9:45 PM"}',
    );
  });

  test("measures Yesterday by calendar day, not by 24 elapsed hours", () => {
    const justAfterMidnight = new Date(2026, 8, 10, 0, 10);
    expect(formatGitLogDate("2026/09/09 23:50", t, justAfterMidnight)).toBe(
      'git.log.dateMinutesAgo:{"count":20}',
    );
    expect(formatGitLogDate("2026/09/09 22:00", t, justAfterMidnight)).toBe(
      'git.log.dateYesterday:{"time":"10:00 PM"}',
    );
  });

  test("falls back to absolute formats for future dates and passes bad input through", () => {
    expect(formatGitLogDate("2026/09/10 16:00", t, now)).toBe(
      'git.log.dateToday:{"time":"4:00 PM"}',
    );
    expect(formatGitLogDate("not a date", t, now)).toBe("not a date");
  });
});
