import { describe, expect, test } from "bun:test";
import { createTranslator } from "@/i18n/locale";
import { formatLocaleDateTime } from "@/platform/system-date-time";
import { formatGitLogDate, parseGitLogDate } from "./git-log-date";

const t = createTranslator("en-US");
const now = new Date(2026, 8, 10, 15, 30);
const local = -now.getTimezoneOffset();

function format(
  value: string,
  offset: number | null | undefined = local,
  clock = now,
  locale = "en-US",
) {
  const date = parseGitLogDate(value, offset);
  return formatGitLogDate(
    value,
    t,
    offset,
    clock,
    date ? formatLocaleDateTime(date, locale) : undefined,
  );
}

describe("formatGitLogDate", () => {
  test("shows translated relative labels for commits within the last hour", () => {
    expect(format("2026/09/10 15:30")).toBe("Just now");
    expect(format("2026/09/10 15:29")).toBe("1 minute ago");
    expect(format("2026/09/10 15:05")).toBe("25 minutes ago");
    expect(format("2026/09/10 14:31")).toBe("59 minutes ago");
  });

  test("uses regional time cycles for Today and Yesterday", () => {
    expect(format("2026/09/10 14:30")).toBe("Today 2:30 PM");
    expect(format("2026/09/10 00:05")).toBe("Today 12:05 AM");
    expect(format("2026/09/09 23:59")).toBe("Yesterday 11:59 PM");
    expect(format("2026/09/09 12:00", local, now, "en-GB")).toBe("Yesterday 12:00");
  });

  test("English regional dates use month/day/year or day/month/year independently of UI language", () => {
    expect(format("2026/09/08 09:07")).toBe("9/8/2026 9:07 AM");
    expect(format("2026/09/08 09:07", local, now, "en-GB")).toBe("08/09/2026 9:07");
    expect(
      formatGitLogDate("2026/09/08 09:07", t, local, now, { date: "2026-09-08", time: "09:07" }),
    ).toBe("2026-09-08 09:07");
  });

  test("measures Yesterday by local calendar day including the year boundary", () => {
    expect(format("2026/09/09 23:50", local, new Date(2026, 8, 10, 0, 10))).toBe("20 minutes ago");
    expect(format("2026/09/09 22:00", local, new Date(2026, 8, 10, 0, 10))).toBe(
      "Yesterday 10:00 PM",
    );
    const winter = new Date(2026, 0, 1, 12);
    expect(format("2025/12/31 21:45", -winter.getTimezoneOffset(), winter)).toBe(
      "Yesterday 9:45 PM",
    );
  });

  test("converts another author's zone to the local instant before relative formatting", () => {
    expect(format("2026/09/10 16:25", local + 60)).toBe("5 minutes ago");
    expect(format("2026/09/10 15:25", local + 60)).toBe("Today 2:25 PM");
    expect(parseGitLogDate("2026/09/10 00:30", 480)?.toISOString()).toBe(
      "2026-09-09T16:30:00.000Z",
    );
  });

  test("keeps dates with unknown offsets absolute", () => {
    expect(format("2026/09/10 15:25", null)).toBe("9/10/2026 3:25 PM");
    expect(
      formatGitLogDate("2026/09/10 15:25", t, undefined, now, {
        date: "9/10/2026",
        time: "3:25 PM",
      }),
    ).toBe("9/10/2026 3:25 PM");
  });

  test("does not emit negative minutes or normalize invalid backend dates", () => {
    expect(format("2026/09/10 16:00")).toBe("Today 4:00 PM");
    for (const invalid of [
      "not a date",
      "2026/02/30 15:00",
      "2026/13/01 15:00",
      "2026/09/10 24:00",
    ]) {
      expect(format(invalid)).toBe(invalid);
    }
    expect(parseGitLogDate("2026/09/10 15:25", Number.NaN)).toBeNull();
  });
});
