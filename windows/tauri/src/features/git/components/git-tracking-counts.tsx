import { cn } from "@/utils/cn";

const MAX_VISIBLE_TRACKING_COUNT = 99;

function normalizeGitTrackingCount(count: number): number {
  return Number.isFinite(count) ? Math.max(0, Math.floor(count)) : 0;
}

export function formatGitTrackingCount(count: number): string {
  const normalized = normalizeGitTrackingCount(count);
  return normalized > MAX_VISIBLE_TRACKING_COUNT
    ? `${MAX_VISIBLE_TRACKING_COUNT}+`
    : String(normalized);
}

export function GitTrackingCounts({
  ahead = 0,
  behind = 0,
  aheadLabel,
  behindLabel,
  showCounts = true,
  className,
}: {
  ahead?: number;
  behind?: number;
  aheadLabel?: string;
  behindLabel?: string;
  showCounts?: boolean;
  className?: string;
}) {
  const normalizedAhead = normalizeGitTrackingCount(ahead);
  const normalizedBehind = normalizeGitTrackingCount(behind);
  if (normalizedAhead === 0 && normalizedBehind === 0) return null;

  return (
    <span
      className={cn(
        "inline-flex shrink-0 items-center gap-1 whitespace-nowrap text-[10px] leading-none tabular-nums",
        className,
      )}
    >
      {normalizedBehind > 0 ? (
        <span className="shrink-0 text-info" aria-label={behindLabel} title={behindLabel}>
          <span aria-hidden="true">↙</span>
          {showCounts ? formatGitTrackingCount(normalizedBehind) : null}
        </span>
      ) : null}
      {normalizedAhead > 0 ? (
        <span className="shrink-0 text-git-added" aria-label={aheadLabel} title={aheadLabel}>
          <span aria-hidden="true">↗</span>
          {showCounts ? formatGitTrackingCount(normalizedAhead) : null}
        </span>
      ) : null}
    </span>
  );
}
