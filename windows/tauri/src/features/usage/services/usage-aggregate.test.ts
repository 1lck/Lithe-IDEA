import { describe, expect, test } from "bun:test";
import {
  accumulate,
  bucketize,
  dedupeRecords,
  emptyTotals,
  startOfMonth,
  startOfToday,
  startOfWeek,
  summarizeByModel,
  summarizeRange,
} from "./usage-aggregate";
import type { UsageRecord } from "../types/usage.types";

function record(overrides: Partial<UsageRecord> & { dedupKey: string; ts: number }): UsageRecord {
  return {
    platform: "claude",
    source: "local-session",
    sessionId: null,
    model: "claude-sonnet-4-5",
    inputTokens: 1_000,
    outputTokens: 500,
    cacheReadTokens: 0,
    cacheWriteTokens: 0,
    totalTokens: 1_500,
    effort: null,
    ...overrides,
  };
}

describe("dedupe", () => {
  test("keeps the first record per platform and id", () => {
    const unique = dedupeRecords([
      record({ dedupKey: "a", ts: 1 }),
      record({ dedupKey: "a", ts: 1 }),
      record({ dedupKey: "b", ts: 2 }),
    ]);
    expect(unique).toHaveLength(2);
  });

  test("does not collapse the same id across platforms", () => {
    // A Claude `message.id` and a Codex `response_id` are two id spaces.
    const unique = dedupeRecords([
      record({ dedupKey: "same", ts: 1 }),
      record({ dedupKey: "same", ts: 1, platform: "codex" }),
    ]);
    expect(unique).toHaveLength(2);
  });
});

describe("totals", () => {
  test("sums tokens and separates records it could not price", () => {
    const totals = emptyTotals();
    accumulate(totals, record({ dedupKey: "priced", ts: 1 }));
    accumulate(totals, record({ dedupKey: "unpriced", ts: 2, model: "mystery-model" }));

    expect(totals.requests).toBe(2);
    expect(totals.inputTokens).toBe(2_000);
    expect(totals.totalTokens).toBe(3_000);
    // The records that can be priced are still priced, and the ones that cannot
    // are counted separately rather than blanking the amount.
    expect(totals.unpricedRequests).toBe(1);
    expect(totals.costUsd).toBeGreaterThan(0);
  });

  test("treats missing token fields as nothing to add", () => {
    const totals = emptyTotals();
    accumulate(
      totals,
      record({
        dedupKey: "partial",
        ts: 1,
        inputTokens: null,
        outputTokens: null,
        totalTokens: null,
      }),
    );
    expect(totals.totalTokens).toBe(0);
    expect(totals.requests).toBe(1);
  });
});

describe("range boundaries", () => {
  const now = new Date(2026, 8, 23, 15, 30).getTime();

  test("today is local midnight of the same date", () => {
    const start = new Date(startOfToday(now));
    expect(start.getDate()).toBe(23);
    expect(start.getHours()).toBe(0);
    expect(start.getMinutes()).toBe(0);
  });

  test("week starts on Monday local midnight", () => {
    const start = new Date(startOfWeek(now));
    expect(start.getDay()).toBe(1);
    expect(start.getHours()).toBe(0);
    expect(now - start.getTime()).toBeLessThan(7 * 24 * 3_600_000);
  });

  test("month starts on the first local midnight", () => {
    const start = new Date(startOfMonth(now));
    expect(start.getDate()).toBe(1);
    expect(start.getMonth()).toBe(8);
    expect(start.getHours()).toBe(0);
  });
});

describe("range filtering", () => {
  const now = new Date(2026, 8, 23, 15, 30).getTime();
  const lateYesterday = new Date(2026, 8, 22, 23, 59, 59).getTime();
  const thisMorning = new Date(2026, 8, 23, 9, 0).getTime();

  test("today takes the left edge in and leaves the future out", () => {
    const summary = summarizeRange(
      [record({ dedupKey: "y", ts: lateYesterday }), record({ dedupKey: "t", ts: thisMorning })],
      "today",
      now,
    );
    expect(summary.totals.requests).toBe(1);
    expect(summary.start).toBe(startOfToday(now));
    expect(summary.end).toBe(now);
  });

  test("a record exactly at the boundary counts", () => {
    const summary = summarizeRange([record({ dedupKey: "edge", ts: thisMorning })], "today", now);
    const atMidnight = new Date(new Date(thisMorning).setHours(0, 0, 0, 0)).getTime();
    const boundary = summarizeRange([record({ dedupKey: "edge", ts: atMidnight })], "today", now);
    expect(summary.totals.requests).toBe(1);
    expect(boundary.totals.requests).toBe(1);
  });

  test("month excludes the last day of the previous month", () => {
    const lastMonth = new Date(2026, 7, 31, 23, 59, 59).getTime();
    const firstOfMonth = new Date(2026, 8, 1, 0, 0, 0).getTime();
    const summary = summarizeRange(
      [record({ dedupKey: "prev", ts: lastMonth }), record({ dedupKey: "cur", ts: firstOfMonth })],
      "month",
      now,
    );
    expect(summary.totals.requests).toBe(1);
  });

  test("total starts at the earliest record, which is not account lifetime", () => {
    const oldest = new Date(2024, 0, 5, 12, 0).getTime();
    const summary = summarizeRange(
      [record({ dedupKey: "old", ts: oldest }), record({ dedupKey: "new", ts: thisMorning })],
      "total",
      now,
    );
    expect(summary.start).toBe(oldest);
    expect(summary.totals.requests).toBe(2);
  });
});

describe("bucketing", () => {
  test("hourly buckets keep the empty hours", () => {
    const start = new Date(2026, 8, 23, 10, 0, 0).getTime();
    const end = new Date(2026, 8, 23, 13, 0, 0).getTime();
    const buckets = bucketize(
      [
        record({ dedupKey: "a", ts: new Date(2026, 8, 23, 10, 30).getTime() }),
        record({ dedupKey: "b", ts: new Date(2026, 8, 23, 12, 15).getTime() }),
      ],
      "hour",
      start,
      end,
    );
    expect(buckets).toHaveLength(3);
    expect(buckets.map((bucket) => bucket.totals.requests)).toEqual([1, 0, 1]);
  });

  test("daily buckets keep the empty days", () => {
    const start = new Date(2026, 8, 21, 0, 0, 0).getTime();
    const end = new Date(2026, 8, 24, 0, 0, 0).getTime();
    const buckets = bucketize(
      [
        record({ dedupKey: "a", ts: new Date(2026, 8, 21, 8, 0).getTime() }),
        record({ dedupKey: "b", ts: new Date(2026, 8, 23, 8, 0).getTime() }),
      ],
      "day",
      start,
      end,
    );
    expect(buckets).toHaveLength(3);
    expect(buckets.map((bucket) => bucket.totals.requests)).toEqual([1, 0, 1]);
  });

  test("drops records outside the window", () => {
    const start = new Date(2026, 8, 23, 10, 0, 0).getTime();
    const end = new Date(2026, 8, 23, 11, 0, 0).getTime();
    const buckets = bucketize(
      [record({ dedupKey: "early", ts: new Date(2026, 8, 23, 9, 0).getTime() })],
      "hour",
      start,
      end,
    );
    expect(buckets).toHaveLength(1);
    expect(buckets[0]?.totals.requests).toBe(0);
  });
});

describe("per model totals", () => {
  const start = new Date(2026, 8, 23, 0, 0, 0).getTime();
  const end = new Date(2026, 8, 24, 0, 0, 0).getTime();
  const inside = new Date(2026, 8, 23, 10, 0).getTime();

  test("groups by platform and model, busiest first", () => {
    const summary = summarizeByModel(
      [
        record({ dedupKey: "a", ts: inside, model: "claude-sonnet-4-5" }),
        record({ dedupKey: "b", ts: inside, model: "claude-sonnet-4-5" }),
        record({ dedupKey: "c", ts: inside, model: "deepseek-flash" }),
      ],
      start,
      end,
    );

    expect(summary.map((entry) => entry.model)).toEqual(["claude-sonnet-4-5", "deepseek-flash"]);
    expect(summary[0]?.totals.requests).toBe(2);
    // A model with no published price is visible as a row, and its cost is
    // counted as unpriced rather than silently dropped.
    expect(summary[1]?.totals.costUsd).toBe(0);
    expect(summary[1]?.totals.unpricedRequests).toBe(1);
  });

  test("the same model on two platforms stays two rows", () => {
    const summary = summarizeByModel(
      [
        record({ dedupKey: "a", ts: inside, model: "shared-model" }),
        record({ dedupKey: "b", ts: inside, model: "shared-model", platform: "codex" }),
      ],
      start,
      end,
    );

    expect(summary).toHaveLength(2);
  });

  test("records outside the window are left out", () => {
    const summary = summarizeByModel(
      [record({ dedupKey: "old", ts: new Date(2026, 8, 20, 10, 0).getTime() })],
      start,
      end,
    );

    expect(summary).toEqual([]);
  });
});
