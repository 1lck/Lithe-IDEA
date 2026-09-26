import { useEffect, useMemo, useState } from "react";
import {
  bucketize,
  rangeStart,
  summarizeByModel,
  summarizeRange,
} from "../services/usage-aggregate";
import {
  formatCost,
  formatTokens,
  formatTokensExact,
  sharePercent,
} from "../services/usage-format";
import type { UsageRangeId, UsageRecord } from "../types/usage.types";
import { UsageBarChart } from "./usage-bar-chart";
import { useTranslation } from "@/i18n/locale-provider";
import { Tabs, TabsList, TabsTrigger } from "@/ui/tabs";
import { cn } from "@/utils/cn";

const RANGE_IDS: readonly UsageRangeId[] = ["today", "week", "month", "total"];

/** The range boundaries follow the clock, so they are re-read while the panel is open. */
const CLOCK_INTERVAL_MS = 60_000;

interface UsageTokensViewProps {
  records: UsageRecord[];
  /** True while the very first scan is running, when zero would be misleading. */
  isFirstScan: boolean;
}

function StatTile({
  label,
  value,
  detail,
  title,
}: {
  label: string;
  value: string;
  detail?: string | null;
  title?: string;
}) {
  return (
    <div className="rounded-(--lithe-chrome-radius) bg-surface/55 px-2.5 py-2">
      <div className="ui-text-caption text-subtle-foreground">{label}</div>
      <div className="ui-text-base mt-0.5 font-medium tabular-nums text-foreground" title={title}>
        {value}
      </div>
      {detail ? (
        <div className="ui-text-caption mt-0.5 truncate text-subtle-foreground">{detail}</div>
      ) : null}
    </div>
  );
}

export function UsageTokensView({ records, isFirstScan }: UsageTokensViewProps) {
  const { t } = useTranslation();
  const [range, setRange] = useState<UsageRangeId>("today");
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    const intervalId = window.setInterval(() => setNow(Date.now()), CLOCK_INTERVAL_MS);
    return () => window.clearInterval(intervalId);
  }, []);

  const start = useMemo(() => rangeStart(range, records, now), [range, records, now]);
  const totals = useMemo(() => summarizeRange(records, range, now).totals, [records, range, now]);
  const unit = range === "today" ? "hour" : "day";
  const buckets = useMemo(() => bucketize(records, unit, start, now), [records, unit, start, now]);
  const models = useMemo(
    () => summarizeByModel(records, start, now).slice(0, 6),
    [records, start, now],
  );

  // The same model name can appear on both platforms - a relay serving the same
  // model to Claude Code and to Codex is exactly how that happens - and two rows
  // reading "deepseek-flash" with different numbers look like a bug. Only those
  // rows get the platform spelled out, so the common case stays uncluttered.
  const ambiguousModelNames = useMemo(() => {
    const counts = new Map<string, number>();
    for (const entry of models) {
      const name = entry.model ?? "";
      counts.set(name, (counts.get(name) ?? 0) + 1);
    }
    return new Set([...counts].filter(([, count]) => count > 1).map(([name]) => name));
  }, [models]);

  const cacheShare = sharePercent(totals.cacheReadTokens, totals.totalTokens);
  // Zero would read as "this was free" when the truth is "nothing here has a
  // published price".
  const isFullyUnpriced = totals.requests > 0 && totals.unpricedRequests === totals.requests;

  return (
    <div className="space-y-3 p-3">
      <Tabs value={range} onValueChange={(value) => setRange(value as UsageRangeId)}>
        <TabsList className="w-full" variant="segmented">
          {RANGE_IDS.map((id) => (
            <TabsTrigger key={id} value={id} size="xs">
              {t(`usageStats.range.${id}`)}
            </TabsTrigger>
          ))}
        </TabsList>
      </Tabs>

      {isFirstScan ? (
        <p className="ui-text-caption py-6 text-center text-subtle-foreground">
          {t("usageStats.firstScan")}
        </p>
      ) : records.length === 0 ? (
        <p className="ui-text-caption py-6 text-center text-subtle-foreground">
          {t("usageStats.empty")}
        </p>
      ) : (
        <>
          <div className="grid grid-cols-2 gap-2">
            <StatTile
              label={t("usageStats.totalTokens")}
              value={formatTokens(totals.totalTokens)}
              detail={t("usageStats.inOut", {
                input: formatTokens(totals.inputTokens),
                output: formatTokens(totals.outputTokens),
              })}
              title={formatTokensExact(totals.totalTokens)}
            />
            <StatTile label={t("usageStats.requests")} value={`${totals.requests}`} />
            <StatTile
              label={t("usageStats.cost")}
              value={isFullyUnpriced ? "—" : formatCost(totals.costUsd)}
              detail={
                totals.unpricedRequests > 0
                  ? t("usageStats.unpriced", { count: totals.unpricedRequests })
                  : null
              }
            />
            <StatTile
              label={t("usageStats.cacheRead")}
              value={formatTokens(totals.cacheReadTokens)}
              detail={
                cacheShare === null
                  ? null
                  : t("usageStats.share", { percent: Math.round(cacheShare) })
              }
              title={formatTokensExact(totals.cacheReadTokens)}
            />
          </div>

          <UsageBarChart buckets={buckets} unit={unit} />

          {models.length > 0 ? (
            <div className="space-y-1">
              <div className="ui-text-caption text-subtle-foreground">
                {t("usageStats.byModel")}
              </div>
              {models.map((entry) => (
                <div
                  key={`${entry.platform}:${entry.model ?? ""}`}
                  className="flex items-center gap-2"
                >
                  <span className="flex min-w-0 flex-1 items-baseline gap-1 font-mono ui-text-caption text-foreground">
                    <span className="truncate">
                      {entry.model ?? t("usageStats.model.unknown")}
                    </span>
                    {ambiguousModelNames.has(entry.model ?? "") ? (
                      <span className="shrink-0 text-subtle-foreground">
                        ·{t(`usage.platform.${entry.platform}`)}
                      </span>
                    ) : null}
                  </span>
                  <span className="shrink-0 ui-text-caption text-subtle-foreground tabular-nums">
                    {t("usageStats.byModel.requests", { count: entry.totals.requests })}
                  </span>
                  <span
                    className="w-14 shrink-0 text-right ui-text-caption text-subtle-foreground tabular-nums"
                    title={formatTokensExact(entry.totals.totalTokens)}
                  >
                    {formatTokens(entry.totals.totalTokens)}
                  </span>
                  <span
                    className={cn(
                      "w-16 shrink-0 text-right ui-text-caption tabular-nums",
                      entry.totals.unpricedRequests > 0
                        ? "text-subtle-foreground/70"
                        : "text-foreground",
                    )}
                  >
                    {entry.totals.unpricedRequests > 0 && entry.totals.costUsd === 0
                      ? t("usageStats.byModel.unpriced")
                      : formatCost(entry.totals.costUsd)}
                  </span>
                </div>
              ))}
            </div>
          ) : null}
        </>
      )}
    </div>
  );
}
