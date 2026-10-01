import { useEffect, useState } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { ClockIcon, GaugeIcon } from "@/ui/icons";
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
  const primary = quota === null ? null : mostUsedQuotaWindow(quota);
  const usage = (window: AgentSubscriptionQuotaWindow) =>
    t("agent.quotaView.used", {
      window: quotaWindowLabel(window.limitSeconds),
      percent: window.usedPercent === null ? "—" : percent(window.usedPercent / 100, 0, language),
    });
  const date = (seconds: number, options: Intl.DateTimeFormatOptions) =>
    new Intl.DateTimeFormat(language, options).format(new Date(seconds * 1000));

  const lines = [t("agent.quotaView.title")];
  if (account !== null) lines.push(account);
  for (const window of quota?.windows ?? []) {
    lines.push(`${window.name === "codex" ? "" : `${window.name} · `}${usage(window)}`);
    if (window.resetsAt !== null) {
      lines.push(
        t("agent.quotaView.resets", {
          time: date(window.resetsAt, {
            month: "short",
            day: "numeric",
            hour: "2-digit",
            minute: "2-digit",
          }),
        }),
      );
    }
  }
  if (quota !== null) {
    lines.push(
      t("agent.quotaView.updated", {
        time: date(quota.fetchedAt, { hour: "2-digit", minute: "2-digit" }),
      }),
    );
  }
  if (failure === "accountChanged" || failure === "unauthorized") {
    lines.push(t("agent.quotaView.accountChanged"));
  } else if (stale) {
    lines.push(t("agent.quotaView.stale"));
  } else if (quota === null) {
    lines.push(t("agent.quotaView.waiting"));
  }
  const details = lines.join("\n");

  const used = primary?.usedPercent ?? 0;
  const tone = stale
    ? "text-subtle-foreground/70"
    : used >= 100
      ? "text-destructive"
      : used >= 90
        ? "text-warning"
        : "text-subtle-foreground";
  const Icon = stale ? ClockIcon : GaugeIcon;

  return (
    <Tooltip side="top" content={details} className="whitespace-pre-line">
      <span
        role="img"
        aria-label={`${t("agent.quotaView.title")}: ${details}`}
        className={cn("flex shrink-0 items-center gap-1 py-1 tabular-nums", tone)}
      >
        <Icon className="size-3" />
        {primary === null ? t("agent.quotaView.unknown") : usage(primary)}
      </span>
    </Tooltip>
  );
}
