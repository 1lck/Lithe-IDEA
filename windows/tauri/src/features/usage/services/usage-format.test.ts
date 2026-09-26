import { describe, expect, test } from "bun:test";
import {
  formatCost,
  formatRecordTime,
  formatTokens,
  formatTokensExact,
  sharePercent,
} from "./usage-format";

describe("token formatting", () => {
  test("keeps small counts exact and compacts large ones", () => {
    expect(formatTokens(0)).toBe("0");
    expect(formatTokens(999)).toBe("999");
    expect(formatTokens(1_500)).toBe("1.5K");
    expect(formatTokens(1_234_567)).toBe("1.2M");
    expect(formatTokens(2_500_000_000)).toBe("2.5B");
  });

  test("rounding never prints a thousand of the unit it chose", () => {
    // 999_950 is below a million, but rounding it in K would print "1000K",
    // which reads as a mistake. It steps up to the larger unit instead.
    expect(formatTokens(999_950)).toBe("1M");
    expect(formatTokens(123_456_789)).toBe("123M");
    // A whole number of a unit drops its decimal rather than printing "1.0K".
    expect(formatTokens(1_010)).toBe("1K");
    expect(formatTokens(1_500)).toBe("1.5K");
  });

  test("a missing count is a dash, never a zero", () => {
    expect(formatTokens(null)).toBe("—");
    expect(formatTokensExact(null)).toBe("—");
  });

  test("the exact form is unambiguous", () => {
    expect(formatTokensExact(1_234_567)).toBe("1,234,567");
  });
});

describe("cost formatting", () => {
  test("below a cent reads as less than a cent, not as free", () => {
    expect(formatCost(0.004)).toBe("<$0.01");
    expect(formatCost(0)).toBe("$0");
    expect(formatCost(null)).toBe("—");
  });

  test("cents are kept for ordinary amounts", () => {
    expect(formatCost(1.234)).toBe("$1.23");
    expect(formatCost(999.5)).toBe("$999.50");
  });
});

describe("request time formatting", () => {
  const now = new Date(2026, 8, 23, 15, 30).getTime();

  test("today is shown as a time, another day carries its date", () => {
    const earlierToday = new Date(2026, 8, 23, 9, 5, 0).getTime();
    expect(formatRecordTime(earlierToday, now)).not.toContain("/");

    const yesterday = new Date(2026, 8, 22, 9, 5, 0).getTime();
    expect(formatRecordTime(yesterday, now)).not.toBe(formatRecordTime(earlierToday, now));
  });
});

describe("share of a whole", () => {
  test("a zero whole has no share rather than a division by zero", () => {
    expect(sharePercent(10, 0)).toBeNull();
    expect(sharePercent(25, 100)).toBe(25);
  });
});
