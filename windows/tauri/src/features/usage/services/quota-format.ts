import type {
  PlatformQuota,
  QuotaPlatformId,
  QuotaWindow,
  TranslateFn,
} from "../types/quota.types";

/** Tone only expresses pressure, never readability — a failed read shows no percentage at all. */
export type QuotaTone = "ok" | "warning" | "danger";

const WARNING_PERCENT = 60;
const DANGER_PERCENT = 85;

export function quotaTone(usedPercent: number): QuotaTone {
  if (usedPercent >= DANGER_PERCENT) return "danger";
  if (usedPercent >= WARNING_PERCENT) return "warning";
  return "ok";
}

/**
 * Picks the tightest window, for the status bar summary.
 * Windows without a percentage rank last: they cannot compete as if they were 0%.
 */
export function mostUrgentWindow(windows: QuotaWindow[]): QuotaWindow | null {
  let best: QuotaWindow | null = null;
  for (const window of windows) {
    if (window.usedPercent === null) {
      best ??= window;
      continue;
    }
    if (best === null || best.usedPercent === null || window.usedPercent > best.usedPercent) {
      best = window;
    }
  }
  return best;
}

export interface UrgentPlatformWindow {
  platform: QuotaPlatformId;
  window: QuotaWindow;
}

/**
 * Picks the tightest window across platforms.
 *
 * The status bar answers "which limit am I closest to", not "how is the
 * selected platform doing". Looking at a single platform would still report
 * 71% while another one sits at 88%, which is exactly what a low-quota warning
 * is supposed to catch. Platforms whose quota could not be read are skipped.
 */
export function mostUrgentPlatformWindow(entries: PlatformQuota[]): UrgentPlatformWindow | null {
  let best: UrgentPlatformWindow | null = null;
  for (const entry of entries) {
    if (entry.failure) continue;
    const window = mostUrgentWindow(entry.windows);
    if (!window) continue;
    if (window.usedPercent === null) {
      best ??= { platform: entry.platform, window };
      continue;
    }
    if (
      best === null ||
      best.window.usedPercent === null ||
      window.usedPercent > best.window.usedPercent
    ) {
      best = { platform: entry.platform, window };
    }
  }
  return best;
}

export function quotaWindowLabel(t: TranslateFn, window: QuotaWindow): string {
  if (window.key === "5h") return t("usage.window.fiveHour");
  if (window.key === "7d") return t("usage.window.sevenDay");
  if (window.key === "7dOpus") return t("usage.window.sevenDayOpus");
  if (window.key === "7dSonnet") return t("usage.window.sevenDaySonnet");
  if (window.limitSeconds === null) return t("usage.window.unknown");
  return t("usage.window.minutes", { count: Math.round(window.limitSeconds / 60) });
}

/**
 * Reset countdown. Returns null once the reset time has passed — the percentage
 * itself is stale by then.
 */
export function formatResetCountdown(resetsAt: string | null, now: number): string | null {
  if (!resetsAt) return null;
  const target = Date.parse(resetsAt);
  if (!Number.isFinite(target)) return null;

  const deltaMs = target - now;
  if (deltaMs <= 0) return null;

  const totalMinutes = Math.floor(deltaMs / 60_000);
  const days = Math.floor(totalMinutes / 1_440);
  const hours = Math.floor((totalMinutes % 1_440) / 60);
  const minutes = totalMinutes % 60;

  if (days > 0) return `${days}d ${hours}h`;
  if (hours > 0) return `${hours}h ${minutes}m`;
  return `${minutes}m`;
}
