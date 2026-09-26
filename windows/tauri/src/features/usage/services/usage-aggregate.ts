import type {
  UsageBucket,
  UsageBucketUnit,
  UsageRangeId,
  UsageRangeTotals,
  UsageRecord,
  UsageTotals,
} from "../types/usage.types";
import { estimateCost } from "./usage-pricing";

export function emptyTotals(): UsageTotals {
  return {
    requests: 0,
    inputTokens: 0,
    outputTokens: 0,
    cacheReadTokens: 0,
    cacheWriteTokens: 0,
    totalTokens: 0,
    costUsd: 0,
    unpricedRequests: 0,
  };
}

/**
 * Adds one record to a running total. A missing token field contributes zero
 * (the same thing SQL's SUM does with NULL), but a record that cannot be priced
 * is counted separately - that count is what the UI marks the cost with.
 */
export function accumulate(totals: UsageTotals, record: UsageRecord): void {
  totals.requests += 1;
  totals.inputTokens += record.inputTokens ?? 0;
  totals.outputTokens += record.outputTokens ?? 0;
  totals.cacheReadTokens += record.cacheReadTokens ?? 0;
  totals.cacheWriteTokens += record.cacheWriteTokens ?? 0;
  totals.totalTokens += record.totalTokens ?? 0;

  const cost = estimateCost(
    record.platform,
    record.model,
    record.inputTokens ?? 0,
    record.outputTokens ?? 0,
    record.cacheWriteTokens ?? 0,
    record.cacheReadTokens ?? 0,
  );
  if (cost === null) {
    totals.unpricedRequests += 1;
  } else {
    totals.costUsd += cost;
  }
}

/**
 * The dedup key is platform plus the source's own id: a Claude `message.id`
 * and a Codex `response_id` are not the same id space.
 */
export function dedupeKeyOf(record: UsageRecord): string {
  return `${record.platform}:${record.dedupKey}`;
}

export function dedupeRecords(records: Iterable<UsageRecord>): UsageRecord[] {
  const seen = new Set<string>();
  const unique: UsageRecord[] = [];
  for (const record of records) {
    const key = dedupeKeyOf(record);
    if (seen.has(key)) continue;
    seen.add(key);
    unique.push(record);
  }
  return unique;
}

function localMidnight(date: Date): number {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
}

export function startOfToday(now: number): number {
  return localMidnight(new Date(now));
}

/**
 * Monday midnight on the local calendar.
 *
 * Stepping back to Monday on the local calendar and only then taking local
 * midnight matters: subtracting 24 hour steps lands on 23:00 or 01:00 of the
 * previous day across a daylight saving change. The week starts on Monday.
 */
export function startOfWeek(now: number): number {
  const monday = new Date(startOfToday(now));
  const daysFromMonday = (monday.getDay() + 6) % 7;
  monday.setDate(monday.getDate() - daysFromMonday);
  return localMidnight(monday);
}

export function startOfMonth(now: number): number {
  const today = new Date(now);
  return new Date(today.getFullYear(), today.getMonth(), 1).getTime();
}

/**
 * Where a range starts. `total` starts at the oldest record on hand, which is
 * the oldest line in the local logs and not the account's lifetime spend, so
 * the wording in the UI must not claim more than that.
 */
export function rangeStart(
  range: UsageRangeId,
  records: readonly UsageRecord[],
  now: number,
): number {
  if (range === "today") return startOfToday(now);
  if (range === "week") return startOfWeek(now);
  if (range === "month") return startOfMonth(now);

  let earliest = now;
  for (const record of records) {
    if (record.ts < earliest) earliest = record.ts;
  }
  return earliest;
}

/** Half-open interval [start, end) */
export function summarizeRange(
  records: readonly UsageRecord[],
  range: UsageRangeId,
  now: number,
): UsageRangeTotals {
  const start = rangeStart(range, records, now);
  const totals = emptyTotals();
  for (const record of records) {
    if (record.ts < start || record.ts >= now) continue;
    accumulate(totals, record);
  }
  return { range, start, end: now, totals };
}

export function bucketStartOf(ts: number, unit: UsageBucketUnit): number {
  if (unit === "day") return localMidnight(new Date(ts));
  const date = new Date(ts);
  return new Date(date.getFullYear(), date.getMonth(), date.getDate(), date.getHours()).getTime();
}

/**
 * Walks the local calendar one unit at a time; a fixed millisecond step would
 * drift across a daylight saving change.
 */
function enumerateBucketStarts(unit: UsageBucketUnit, start: number, end: number): number[] {
  const starts: number[] = [];
  if (unit === "day") {
    const cursor = new Date(localMidnight(new Date(start)));
    while (cursor.getTime() < end) {
      starts.push(cursor.getTime());
      cursor.setDate(cursor.getDate() + 1);
      cursor.setTime(localMidnight(cursor));
    }
    return starts;
  }

  const cursor = new Date(start);
  cursor.setMinutes(0, 0, 0);
  while (cursor.getTime() < end) {
    starts.push(cursor.getTime());
    cursor.setHours(cursor.getHours() + 1);
  }
  return starts;
}

/**
 * Empty buckets are returned too: on a trend chart, "nothing was used then" and
 * "there is no data for then" are not the same thing.
 */
export function bucketize(
  records: readonly UsageRecord[],
  unit: UsageBucketUnit,
  start: number,
  end: number,
): UsageBucket[] {
  const buckets = new Map<number, UsageTotals>();
  for (const bucketStart of enumerateBucketStarts(unit, start, end)) {
    buckets.set(bucketStart, emptyTotals());
  }

  for (const record of records) {
    if (record.ts < start || record.ts >= end) continue;
    const totals = buckets.get(bucketStartOf(record.ts, unit));
    if (totals) accumulate(totals, record);
  }

  // A Map keeps insertion order, and the insertion order is the chronological
  // order enumerateBucketStarts produced.
  return [...buckets].map(([start, totals]) => ({ start, totals }));
}

export interface UsageModelSummary {
  platform: UsageRecord["platform"];
  /** null when the log did not name the model. */
  model: string | null;
  totals: UsageTotals;
}

/**
 * One row per platform and model inside the window, busiest first.
 *
 * This is also what answers "why does the total say estimate": a custom
 * provider model has no published price, and it shows up here as a row whose
 * cost is a dash rather than being quietly folded into the number.
 */
export function summarizeByModel(
  records: readonly UsageRecord[],
  start: number,
  end: number,
): UsageModelSummary[] {
  const groups = new Map<string, UsageModelSummary>();

  for (const record of records) {
    if (record.ts < start || record.ts >= end) continue;
    const key = `${record.platform}\u0000${record.model ?? ""}`;
    let group = groups.get(key);
    if (!group) {
      group = { platform: record.platform, model: record.model, totals: emptyTotals() };
      groups.set(key, group);
    }
    accumulate(group.totals, record);
  }

  return [...groups.values()].sort(
    (left, right) =>
      right.totals.totalTokens - left.totals.totalTokens ||
      right.totals.requests - left.totals.requests,
  );
}
