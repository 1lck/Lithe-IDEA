import { useMemo, useState, type ReactNode } from "react";
import { estimateCost } from "../services/usage-pricing";
import {
  formatCost,
  formatRecordTime,
  formatTokens,
  formatTokensExact,
} from "../services/usage-format";
import type { UsagePlatformId, UsageRecord } from "../types/usage.types";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { Tabs, TabsList, TabsTrigger } from "@/ui/tabs";
import { cn } from "@/utils/cn";

const PAGE_SIZE = 50;

type PlatformFilter = "all" | UsagePlatformId;

interface UsageLogViewProps {
  records: UsageRecord[];
  isFirstScan: boolean;
}

function Cell({
  children,
  className,
  title,
}: {
  children: ReactNode;
  className?: string;
  title?: string;
}) {
  return (
    <span className={cn("truncate tabular-nums", className)} title={title}>
      {children}
    </span>
  );
}

export function UsageLogView({ records, isFirstScan }: UsageLogViewProps) {
  const { t } = useTranslation();
  const [filter, setFilter] = useState<PlatformFilter>("all");
  const [limit, setLimit] = useState(PAGE_SIZE);

  // Newest first on a sorted copy, so the ledger itself stays append-only.
  const rows = useMemo(() => {
    const matching = filter === "all" ? records : records.filter((r) => r.platform === filter);
    return [...matching].sort((left, right) => right.ts - left.ts).slice(0, limit);
  }, [records, filter, limit]);

  const now = Date.now();

  return (
    <div className="flex min-h-0 flex-col">
      <div className="border-border/70 border-b px-3 py-2">
        <Tabs value={filter} onValueChange={(value) => setFilter(value as PlatformFilter)}>
          <TabsList className="w-full" variant="segmented">
            <TabsTrigger value="all" size="xs">
              {t("usageStats.log.all")}
            </TabsTrigger>
            <TabsTrigger value="claude" size="xs">
              {t("usage.platform.claude")}
            </TabsTrigger>
            <TabsTrigger value="codex" size="xs">
              {t("usage.platform.codex")}
            </TabsTrigger>
          </TabsList>
        </Tabs>
      </div>

      {isFirstScan ? (
        <p className="ui-text-caption py-6 text-center text-subtle-foreground">
          {t("usageStats.firstScan")}
        </p>
      ) : rows.length === 0 ? (
        <p className="ui-text-caption py-6 text-center text-subtle-foreground">
          {t("usageStats.log.empty")}
        </p>
      ) : (
        <>
          <div className="flex items-center gap-2 border-border/70 border-b px-3 py-1.5 ui-text-caption text-subtle-foreground">
            <Cell className="w-[60px] shrink-0">{t("usageStats.log.time")}</Cell>
            <Cell className="min-w-0 flex-1">{t("usageStats.log.model")}</Cell>
            <Cell className="w-11 shrink-0 text-right">{t("usageStats.log.input")}</Cell>
            <Cell className="w-11 shrink-0 text-right">{t("usageStats.log.output")}</Cell>
            <Cell className="w-11 shrink-0 text-right">{t("usageStats.log.total")}</Cell>
          </div>

          <div className="divide-y divide-border/50">
            {rows.map((record) => {
              const cost = estimateCost(
                record.platform,
                record.model,
                record.inputTokens ?? 0,
                record.outputTokens ?? 0,
                record.cacheWriteTokens ?? 0,
                record.cacheReadTokens ?? 0,
              );
              // The narrow pane cannot hold every column, so the two that lost
              // their place (effort, cache reads, cost) stay reachable on hover.
              const rowTitle = [
                t(`usage.platform.${record.platform}`),
                `${t("usageStats.log.effort")} ${record.effort ?? "—"}`,
                `${t("usageStats.log.cache")} ${formatTokensExact(record.cacheReadTokens)}`,
                `${t("usageStats.log.cost")} ${formatCost(cost)}`,
              ].join(" · ");
              return (
                <div
                  key={`${record.platform}:${record.dedupKey}`}
                  className="flex items-center gap-2 px-3 py-1 font-mono ui-text-caption text-foreground hover:bg-accent/40"
                  title={rowTitle}
                >
                  <Cell className="w-[60px] shrink-0 text-subtle-foreground">
                    {formatRecordTime(record.ts, now)}
                  </Cell>
                  <Cell className="min-w-0 flex-1" title={record.model ?? undefined}>
                    {record.model ?? "—"}
                  </Cell>
                  <Cell
                    className="w-11 shrink-0 text-right"
                    title={formatTokensExact(record.inputTokens)}
                  >
                    {formatTokens(record.inputTokens)}
                  </Cell>
                  <Cell
                    className="w-11 shrink-0 text-right"
                    title={formatTokensExact(record.outputTokens)}
                  >
                    {formatTokens(record.outputTokens)}
                  </Cell>
                  <Cell
                    className="w-11 shrink-0 text-right font-medium"
                    title={formatTokensExact(record.totalTokens)}
                  >
                    {formatTokens(record.totalTokens)}
                  </Cell>
                </div>
              );
            })}
          </div>

          {rows.length >= limit ? (
            <div className="p-2">
              <Button
                type="button"
                variant="ghost"
                size="xs"
                className="w-full"
                onClick={() => setLimit((current) => current + PAGE_SIZE)}
              >
                {t("usageStats.log.showMore")}
              </Button>
            </div>
          ) : null}
        </>
      )}
    </div>
  );
}
