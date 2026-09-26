import type { UsageBucketUnit } from "../types/usage.types";

const TOKEN_UNITS = [
  { threshold: 1_000_000_000, suffix: "B" },
  { threshold: 1_000_000, suffix: "M" },
  { threshold: 1_000, suffix: "K" },
] as const;

/** Whole numbers of a unit keep no decimal; the rest keep exactly one. */
function scaleForDisplay(scaled: number): number {
  return scaled >= 100 ? Math.round(scaled) : Math.round(scaled * 10) / 10;
}

/** Compact token counts for tiles and table cells. */
export function formatTokens(value: number | null): string {
  if (value === null || !Number.isFinite(value)) return "—";
  const magnitude = Math.abs(value);
  if (magnitude < 1_000) return `${Math.round(value)}`;

  const sign = value < 0 ? "-" : "";
  for (let index = 0; index < TOKEN_UNITS.length; index += 1) {
    const unit = TOKEN_UNITS[index]!;
    const scaled = magnitude / unit.threshold;
    if (scaled < 1) continue;

    const rounded = scaleForDisplay(scaled);
    if (rounded < 1_000) return `${sign}${rounded}${unit.suffix}`;

    // Rounding reached a thousand of this unit, which means the unit above is
    // the one to print - "1000K" for what is a million reads as a mistake.
    const larger = TOKEN_UNITS[index - 1];
    if (!larger) return `${sign}${Math.round(scaled)}${unit.suffix}`;
    return `${sign}${scaleForDisplay(scaled / 1_000)}${larger.suffix}`;
  }

  return `${Math.round(value)}`;
}

/** The exact count, for a tooltip or title where the compact form is not enough. */
export function formatTokensExact(value: number | null): string {
  if (value === null || !Number.isFinite(value)) return "—";
  return Math.round(value).toLocaleString();
}

/**
 * An estimated amount. Below a cent the exact figure would read as `$0.00`,
 * which looks like "free" rather than "almost nothing", so it is written as
 * less-than a cent.
 */
export function formatCost(usd: number | null): string {
  if (usd === null || !Number.isFinite(usd)) return "—";
  if (usd <= 0) return "$0";
  if (usd < 0.01) return "<$0.01";
  if (usd < 1000) return `$${usd.toFixed(2)}`;
  return `$${Math.round(usd).toLocaleString()}`;
}

export function isSameLocalDay(left: number, right: number): boolean {
  const a = new Date(left);
  const b = new Date(right);
  return (
    a.getFullYear() === b.getFullYear() &&
    a.getMonth() === b.getMonth() &&
    a.getDate() === b.getDate()
  );
}

/** A request timestamp: the time alone when it is from today, otherwise with its date. */
export function formatRecordTime(ts: number, now: number): string {
  const time = new Date(ts).toLocaleTimeString(undefined, {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
  if (isSameLocalDay(ts, now)) return time;
  const date = new Date(ts).toLocaleDateString(undefined, { month: "numeric", day: "numeric" });
  return `${date} ${time}`;
}

export function formatBucketLabel(start: number, unit: UsageBucketUnit): string {
  if (unit === "hour") {
    return new Date(start).toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" });
  }
  return new Date(start).toLocaleDateString(undefined, { month: "numeric", day: "numeric" });
}

/** A percentage of a whole, or null when the whole is zero. */
export function sharePercent(part: number, whole: number): number | null {
  if (!Number.isFinite(part) || !Number.isFinite(whole) || whole <= 0) return null;
  return (part / whole) * 100;
}
