import { formatBucketLabel, formatTokensExact } from "../services/usage-format";
import type { UsageBucket, UsageBucketUnit } from "../types/usage.types";
import { useTranslation } from "@/i18n/locale-provider";
import { cn } from "@/utils/cn";

interface UsageBarChartProps {
  buckets: UsageBucket[];
  unit: UsageBucketUnit;
}

/**
 * A trend of total tokens per bucket, built from plain elements rather than a
 * charting library: one bar per bucket is all this needs.
 *
 * Empty buckets are drawn as a baseline rather than left out, so a gap in the
 * chart reads as "nothing was used then" instead of a missing hour.
 */
export function UsageBarChart({ buckets, unit }: UsageBarChartProps) {
  const { t } = useTranslation();
  const peak = buckets.reduce((highest, bucket) => Math.max(highest, bucket.totals.totalTokens), 0);

  if (buckets.length === 0 || peak === 0) {
    return (
      <div className="flex h-24 items-center justify-center ui-text-caption text-subtle-foreground">
        {t("usageStats.chart.empty")}
      </div>
    );
  }

  // Past a certain number of buckets a gap costs more than it explains.
  const isDense = buckets.length > 60;

  return (
    <div className="space-y-1">
      <div
        className={cn("grid h-24 items-end", isDense ? "gap-px" : "gap-0.5")}
        style={{ gridTemplateColumns: `repeat(${buckets.length}, minmax(0, 1fr))` }}
      >
        {buckets.map((bucket) => {
          const isUsed = bucket.totals.totalTokens > 0;
          const height = isUsed ? Math.max((bucket.totals.totalTokens / peak) * 100, 3) : 2;
          return (
            <div
              key={bucket.start}
              className={cn("w-full rounded-sm", isUsed ? "bg-primary/55" : "bg-accent")}
              style={{ height: `${height}%` }}
              title={`${formatBucketLabel(bucket.start, unit)} · ${formatTokensExact(
                bucket.totals.totalTokens,
              )}`}
            />
          );
        })}
      </div>
      <div className="flex items-center justify-between ui-text-caption text-subtle-foreground">
        <span>{formatBucketLabel(buckets[0]!.start, unit)}</span>
        <span className="flex-1 truncate px-2 text-center">
          {unit === "hour" ? t("usageStats.chart.hourly") : t("usageStats.chart.daily")}
        </span>
        <span>{formatBucketLabel(buckets[buckets.length - 1]!.start, unit)}</span>
      </div>
    </div>
  );
}
