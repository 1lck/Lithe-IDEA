import { useTranslation } from "@/i18n/locale-provider";
import Tooltip from "@/ui/tooltip";
import { cn } from "@/utils/cn";
import {
  isQuotaStale,
  mostUsedQuotaWindow,
  type AgentContextUsage,
  type AgentSubscriptionQuota,
} from "../types/agent.types";

/** `1d`, `7d`, `4h` — the shape the quota windows are named with on macOS. */
function windowLabel(seconds: number): string {
  if (seconds >= 86_400) return `${Math.round(seconds / 86_400)}d`;
  if (seconds >= 3_600) return `${Math.round(seconds / 3_600)}h`;
  return `${Math.max(1, Math.round(seconds / 60))}m`;
}

function percentLabel(usedPercent: number | null): string {
  return usedPercent === null ? "—" : `${Math.round(usedPercent)}%`;
}

interface AgentUsagePanelProps {
  usage: AgentContextUsage | null;
  /** Only present on a Codex subscription connection. */
  quota: AgentSubscriptionQuota | null;
}

/**
 * Occupancy of the current conversation plus the subscription windows, in the
 * composer's footer. An unknown value stays a dash instead of becoming 0%, and
 * a snapshot older than the refresh window is dimmed rather than presented as
 * current.
 */
export function AgentUsagePanel({ usage, quota }: AgentUsagePanelProps) {
  const { t } = useTranslation();
  const primary = quota === null ? null : mostUsedQuotaWindow(quota);
  const stale = quota !== null && isQuotaStale(quota, Date.now() / 1000);

  return (
    <div className="flex items-center gap-3 text-subtle-foreground ui-text-xs">
      <Tooltip
        side="top"
        content={
          usage === null
            ? t("agent.usage.unknown")
            : t("agent.usage.tokens", {
                used: usage.usedTokens.toLocaleString(),
                capacity: usage.capacityTokens.toLocaleString(),
              })
        }
      >
        <span className="flex items-center gap-1.5 tabular-nums">
          <span
            aria-hidden
            className="inline-block size-2.5 rounded-full border border-border-strong"
            style={{
              background:
                usage === null
                  ? "transparent"
                  : `conic-gradient(currentColor ${usage.fraction * 360}deg, transparent 0deg)`,
            }}
          />
          {usage === null ? "—" : `${Math.round(usage.fraction * 100)}%`}
        </span>
      </Tooltip>
      {quota === null ? null : (
        <Tooltip
          side="top"
          content={quota.windows
            .map((entry) => {
              const reset =
                entry.resetsAt === null
                  ? ""
                  : ` (${t("agent.quota.resetsAt", {
                      time: new Date(entry.resetsAt * 1000).toLocaleString(),
                    })})`;
              return `${windowLabel(entry.limitSeconds)} ${percentLabel(entry.usedPercent)}${reset}`;
            })
            .join(" · ")}
        >
          <span className={cn("tabular-nums", stale && "opacity-60")}>
            {primary === null || primary.usedPercent === null
              ? t("agent.quota.unknown", { window: windowLabel(primary?.limitSeconds ?? 0) })
              : t("agent.quota.primary", {
                  window: windowLabel(primary.limitSeconds),
                  percent: percentLabel(primary.usedPercent),
                })}
          </span>
        </Tooltip>
      )}
    </div>
  );
}
