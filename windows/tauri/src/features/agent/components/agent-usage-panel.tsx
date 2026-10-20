import { useEffect, useState } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { HoverCard, HoverCardContent, HoverCardTrigger } from "@/ui/hover-card";
import Tooltip from "@/ui/tooltip";
import { cn } from "@/utils/cn";
import { contextUsageDetails, quotaWindowLabel } from "../services/agent-session-selectors";
import {
  isQuotaStale,
  mostUsedQuotaWindow,
  type AgentContextUsage,
  type AgentSubscriptionQuota,
  type AgentSubscriptionQuotaWindow,
} from "../types/agent.types";

function percent(fraction: number, digits: number, locale: string): string {
  return new Intl.NumberFormat(locale, {
    style: "percent",
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  }).format(fraction);
}

/**
 * Compact context ring with a zero placeholder until the Agent reports usage,
 * as `AgentContextUsageView` on macOS: warning from 90%, error from 100%.
 */
export function AgentContextUsageView({ usage }: { usage: AgentContextUsage | null }) {
  const { t, language } = useTranslation();
  const details = contextUsageDetails(usage, {
    percent: (fraction, digits) => percent(fraction, digits, language),
    placeholder: (value) => t("agent.context.placeholder", { percent: value }),
    tokens: (value, used, capacity) =>
      t("agent.context.tokens", { percent: value, used, capacity }),
  });
  const fraction = usage?.fraction ?? 0;
  const tone =
    usage === null
      ? "text-subtle-foreground/70"
      : fraction >= 1
        ? "text-destructive"
        : fraction >= 0.9
          ? "text-warning"
          : "text-subtle-foreground";
  const circumference = 2 * Math.PI * 5;
  return (
    <Tooltip side="top" content={details}>
      <span
        role="img"
        aria-label={`${t("agent.context.label")}: ${details}`}
        className={cn("flex items-center gap-1 py-1 tabular-nums", tone)}
      >
        <svg aria-hidden viewBox="0 0 12 12" className="size-3 -rotate-90">
          <circle
            cx="6"
            cy="6"
            r="5"
            fill="none"
            stroke="currentColor"
            strokeOpacity={0.3}
            strokeWidth={1.5}
          />
          {usage === null ? null : (
            <circle
              cx="6"
              cy="6"
              r="5"
              fill="none"
              stroke="currentColor"
              strokeWidth={1.5}
              strokeLinecap="round"
              strokeDasharray={`${Math.min(fraction, 1) * circumference} ${circumference}`}
            />
          )}
        </svg>
        {percent(fraction, 0, language)}
      </span>
    </Tooltip>
  );
}

/**
 * The most used subscription window, as `AgentSubscriptionQuotaView` on macOS.
 * Only a subscription connection mounts it; it owns no network or credentials.
 */
const FIVE_HOURS_SECONDS = 5 * 3_600;
const SEVEN_DAYS_SECONDS = 7 * 86_400;

/** 5-hour and weekly windows first, then any provider-specific window. */
function orderedQuotaWindows(
  quota: AgentSubscriptionQuota | null,
): AgentSubscriptionQuotaWindow[] {
  const priority = (window: AgentSubscriptionQuotaWindow) =>
    window.limitSeconds === FIVE_HOURS_SECONDS
      ? 0
      : window.limitSeconds === SEVEN_DAYS_SECONDS
        ? 1
        : 2;
  return (quota?.windows ?? []).slice().sort((left, right) => {
    if (priority(left) !== priority(right)) return priority(left) - priority(right);
    if ((left.name === "codex") !== (right.name === "codex")) {
      return left.name === "codex" ? -1 : 1;
    }
    if (left.limitSeconds !== right.limitSeconds) {
      return left.limitSeconds - right.limitSeconds;
    }
    return left.id.localeCompare(right.id);
  });
}

type QuotaTone = "normal" | "warning" | "error" | "unknown";

function quotaTone(usedPercent: number | null, stale: boolean): QuotaTone {
  if (stale || usedPercent === null) return "unknown";
  if (usedPercent > 90) return "error";
  if (usedPercent > 60) return "warning";
  return "normal";
}

const QUOTA_STROKE: Record<QuotaTone, string> = {
  normal: "stroke-success",
  warning: "stroke-warning",
  error: "stroke-destructive",
  unknown: "stroke-subtle-foreground/60",
};

const QUOTA_TEXT: Record<QuotaTone, string> = {
  normal: "text-success",
  warning: "text-warning",
  error: "text-destructive",
  unknown: "text-subtle-foreground",
};

/**
 * A single ring like Claude Desktop, as `AgentSubscriptionQuotaView` on macOS:
 * a gray track filled by the most used window, with the window breakdown only
 * in the hover card. Only a subscription connection mounts it.
 */
export function AgentSubscriptionQuotaView({
  quota,
  account,
  failure,
}: {
  quota: AgentSubscriptionQuota | null;
  account: string | null;
  failure: string | null;
}) {
  const { t, language } = useTranslation();
  // Re-evaluate staleness every minute without republishing the conversation.
  const [now, setNow] = useState(() => Date.now() / 1000);
  useEffect(() => {
    const handle = setInterval(() => setNow(Date.now() / 1000), 60_000);
    return () => clearInterval(handle);
  }, []);

  const stale = failure !== null || (quota !== null && isQuotaStale(quota, now));
  const windows = orderedQuotaWindows(quota);
  const ring = (quota === null ? null : mostUsedQuotaWindow(quota)) ?? windows[0] ?? null;
  const tone = quotaTone(ring?.usedPercent ?? null, stale);
  const date = (seconds: number) =>
    new Intl.DateTimeFormat(language, {
      month: "short",
      day: "numeric",
      hour: "2-digit",
      minute: "2-digit",
    }).format(new Date(seconds * 1000));
  const windowTitle = (window: AgentSubscriptionQuotaWindow): string => {
    const label =
      window.limitSeconds === FIVE_HOURS_SECONDS
        ? t("agent.quotaView.fiveHours")
        : window.limitSeconds === SEVEN_DAYS_SECONDS
          ? t("agent.quotaView.sevenDays")
          : quotaWindowLabel(window.limitSeconds);
    return window.name === "codex" ? label : `${window.name} · ${label}`;
  };
  const percentLabel = (window: AgentSubscriptionQuotaWindow): string =>
    window.usedPercent === null ? "—" : percent(window.usedPercent / 100, 0, language);
  const value = ring === null ? t("agent.quotaView.unknown") : percentLabel(ring);
  const notice =
    failure === "accountChanged" || failure === "unauthorized"
      ? t("agent.quotaView.accountChanged")
      : stale
        ? t("agent.quotaView.stale")
        : quota === null
          ? t("agent.quotaView.waiting")
          : null;

  const circumference = 2 * Math.PI * 5.5;
  return (
    <HoverCard>
      <HoverCardTrigger
        render={<span role="img" tabIndex={0} />}
        aria-label={`${t("agent.quotaView.title")}: ${value}`}
        className="flex size-7 shrink-0 cursor-default items-center justify-center rounded hover:bg-accent"
      >
        <svg aria-hidden viewBox="0 0 14 14" className="size-3.5 -rotate-90">
          <circle
            cx="7"
            cy="7"
            r="5.5"
            fill="none"
            strokeWidth={2}
            className="stroke-subtle-foreground/40"
          />
          {ring?.usedPercent === null || ring?.usedPercent === undefined ? null : (
            <circle
              cx="7"
              cy="7"
              r="5.5"
              fill="none"
              strokeWidth={2}
              strokeLinecap="round"
              strokeDasharray={`${Math.min(Math.max(ring.usedPercent / 100, 0), 1) * circumference} ${circumference}`}
              className={QUOTA_STROKE[tone]}
            />
          )}
        </svg>
      </HoverCardTrigger>
      <HoverCardContent side="top" align="end" className="w-64">
        <div className="flex flex-col gap-3.5">
          <div className="flex flex-col gap-1">
            <div className="font-semibold ui-text-xs">{t("agent.quotaView.title")}</div>
            {account === null ? null : (
              <div className="truncate ui-text-caption text-subtle-foreground">{account}</div>
            )}
          </div>
          {windows.map((window) => {
            const windowTone = quotaTone(window.usedPercent, stale);
            return (
              <div key={window.id} className="flex flex-col gap-1.5">
                <div className="flex items-center justify-between gap-2 ui-text-caption">
                  <span className="truncate">{windowTitle(window)}</span>
                  <span className={cn("shrink-0 tabular-nums", QUOTA_TEXT[windowTone])}>
                    {t("agent.quotaView.usedPercent", { percent: percentLabel(window) })}
                  </span>
                </div>
                <div className="h-1.5 overflow-hidden rounded-full bg-subtle-foreground/25">
                  {window.usedPercent === null ? null : (
                    <div
                      className={cn(
                        "h-full rounded-full",
                        windowTone === "normal"
                          ? "bg-success"
                          : windowTone === "warning"
                            ? "bg-warning"
                            : windowTone === "error"
                              ? "bg-destructive"
                              : "bg-subtle-foreground/60",
                      )}
                      style={{
                        width: `${Math.min(Math.max(window.usedPercent / 100, 0), 1) * 100}%`,
                      }}
                    />
                  )}
                </div>
                {window.resetsAt === null ? null : (
                  <div className="ui-text-caption text-subtle-foreground">
                    {t("agent.quotaView.resets", { time: date(window.resetsAt) })}
                  </div>
                )}
              </div>
            );
          })}
          {notice === null ? null : (
            <div className="ui-text-caption text-subtle-foreground">{notice}</div>
          )}
        </div>
      </HoverCardContent>
    </HoverCard>
  );
}
