import { describe, expect, test } from "bun:test";
import {
  formatResetCountdown,
  mostUrgentPlatformWindow,
  mostUrgentWindow,
  quotaTone,
  quotaWindowLabel,
} from "./quota-format";
import type { PlatformQuota, QuotaWindow } from "../types/quota.types";

function window(overrides: Partial<QuotaWindow> & { key: string }): QuotaWindow {
  return { usedPercent: null, resetsAt: null, limitSeconds: null, ...overrides };
}

function platformQuota(
  platform: PlatformQuota["platform"],
  windows: QuotaWindow[],
  overrides: Partial<PlatformQuota> = {},
): PlatformQuota {
  return {
    platform,
    connection: "auth",
    windows,
    failure: null,
    detail: null,
    scannedPaths: [],
    plan: null,
    fetchedAt: null,
    ...overrides,
  };
}


describe("most urgent window", () => {
  test("picks the highest used percent", () => {
    const picked = mostUrgentWindow([
      window({ key: "5h", usedPercent: 18 }),
      window({ key: "7d", usedPercent: 59 }),
    ]);
    expect(picked?.key).toBe("7d");
  });

  test("never lets a missing percentage win the comparison", () => {
    // Treating a missing value as 0 would show "5h 0%" when the source simply did not report it
    const picked = mostUrgentWindow([window({ key: "5h" }), window({ key: "7d", usedPercent: 3 })]);
    expect(picked?.key).toBe("7d");
  });

  test("returns null when there is nothing to show", () => {
    expect(mostUrgentWindow([])).toBeNull();
  });
});

describe("quota tone", () => {
  test("escalates with usage", () => {
    expect(quotaTone(0)).toBe("ok");
    expect(quotaTone(59)).toBe("ok");
    expect(quotaTone(60)).toBe("warning");
    expect(quotaTone(85)).toBe("danger");
    expect(quotaTone(100)).toBe("danger");
  });
});

describe("reset countdown", () => {
  const now = Date.parse("2026-09-23T12:00:00.000Z");

  test("formats days, hours and minutes", () => {
    expect(formatResetCountdown("2026-09-26T19:00:00.000Z", now)).toBe("3d 7h");
    expect(formatResetCountdown("2026-09-23T16:51:00.000Z", now)).toBe("4h 51m");
    expect(formatResetCountdown("2026-09-23T12:07:00.000Z", now)).toBe("7m");
  });

  test("returns nothing for elapsed or unusable timestamps", () => {
    // A passed reset time means the percentage itself is stale; a countdown
    // would be worse than nothing
    expect(formatResetCountdown("2026-09-23T11:00:00.000Z", now)).toBeNull();
    expect(formatResetCountdown("not-a-date", now)).toBeNull();
    expect(formatResetCountdown(null, now)).toBeNull();
  });
});

describe("window labels", () => {
  const t = (key: string) => key;

  test("names the known windows", () => {
    expect(quotaWindowLabel(t, window({ key: "5h" }))).toBe("usage.window.fiveHour");
    expect(quotaWindowLabel(t, window({ key: "7dOpus" }))).toBe("usage.window.sevenDayOpus");
  });

  test("falls back to the length for provider-specific windows", () => {
    expect(quotaWindowLabel(t, window({ key: "45m", limitSeconds: 2_700 }))).toBe(
      "usage.window.minutes",
    );
    expect(quotaWindowLabel(t, window({ key: "?" }))).toBe("usage.window.unknown");
  });
});


describe("most urgent platform window", () => {
  test("compares across platforms instead of trusting the first one", () => {
    // Trusting the first platform would still report 71% while another sits at 88%
    const picked = mostUrgentPlatformWindow([
      platformQuota("claude", [window({ key: "7d", usedPercent: 71 })]),
      platformQuota("codex", [window({ key: "5h", usedPercent: 88 })]),
    ]);
    expect(picked?.platform).toBe("codex");
    expect(picked?.window.key).toBe("5h");
  });

  test("skips platforms whose quota could not be read", () => {
    // A platform we cannot read is "unknown": it neither competes nor counts as 0%
    const picked = mostUrgentPlatformWindow([
      platformQuota("claude", [window({ key: "5h", usedPercent: 99 })], {
        connection: "relay",
        failure: "unsupported",
      }),
      platformQuota("codex", [window({ key: "5h", usedPercent: 12 })]),
    ]);
    expect(picked?.platform).toBe("codex");
  });

  test("returns null when nothing is readable", () => {
    expect(mostUrgentPlatformWindow([])).toBeNull();
    expect(
      mostUrgentPlatformWindow([
        platformQuota("claude", [], { connection: "none", failure: "unavailable" }),
      ]),
    ).toBeNull();
  });
});
